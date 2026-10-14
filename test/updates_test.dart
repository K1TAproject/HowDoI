import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled version is the single pubspec version', () async {
    expect(
      await appVersion(),
      versionFromPubspec(File('pubspec.yaml').readAsStringSync()),
    );
    expect(compareVersions('0.1.10', '0.1.2+3'), greaterThan(0));
    expect(compareVersions('0.1.2', '0.1.2+3'), lessThan(0));
    expect(() => compareVersions('../x', '0.1.2'), throwsFormatException);
  });
  group('real HTTP fixtures', () {
    late HttpServer server;
    late Directory dir;
    late ReleaseClient client;
    late String base;
    var status = 200;
    Map<String, dynamic> metadata = {};
    List<int> payload = utf8.encode('download fixture');
    setUp(() async {
      HttpOverrides.global = null;
      dir = Directory.systemTemp.createTempSync('howdoi-download-');
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';
      status = 200;
      metadata = {
        'draft': false,
        'prerelease': false,
        'tag_name': 'v0.1.3',
        'assets': [
          {
            'name': 'HowDoI-0.1.3-windows-x64.zip',
            'browser_download_url': '$base/package',
            'size': payload.length,
            'digest': 'sha256:${sha256.convert(payload)}',
          },
        ],
      };
      server.listen((request) async {
        request.response.statusCode = status;
        if (request.uri.path == '/latest') {
          request.response.write(jsonEncode(metadata));
        } else if (request.uri.path == '/sums') {
          request.response.write(
            '${sha256.convert(payload)}  HowDoI-0.1.3-windows-x64.zip\n',
          );
        } else {
          request.response.add(payload);
        }
        await request.response.close();
      });
      client = ReleaseClient(api: Uri.parse('$base/latest'));
    });
    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
    test('404 and current releases report truthfully', () async {
      status = 404;
      expect((await client.check('0.1.2')).message, contains('404'));
      status = 200;
      expect((await client.check('0.1.3+1')).release, isNull);
      expect((await client.check('0.1.3+1')).message, contains('没有更新版本'));
    });
    test('digest and checksum-file downloads verify identical bytes', () async {
      var result = await client.check('0.1.2');
      expect(result.release!.version, '0.1.3');
      var file = await client.download(result.release!, dir, (_) {});
      expect(await file.readAsBytes(), payload);
      metadata['assets'][0].remove('digest');
      metadata['assets'].add({
        'name': 'SHA256SUMS.txt',
        'browser_download_url': '$base/sums',
      });
      result = await client.check('0.1.2');
      file = await client.download(result.release!, dir, (_) {});
      expect(await file.readAsBytes(), payload);
    });
    test('HTTP errors, missing package and missing checksum', () async {
      status = 503;
      await expectLater(client.check('0.1.2'), throwsA(isA<HttpException>()));
      status = 200;
      metadata['assets'][0].remove('digest');
      await expectLater(client.check('0.1.2'), throwsFormatException);
      metadata['assets'] = [];
      expect((await client.check('0.1.2')).message, contains('尚未提供'));
    });
    for (final failure in ['checksum', 'truncated', 'oversized', 'http']) {
      test(
        '$failure download leaves no partial package or modified current files',
        () async {
          final existing = File('${dir.path}/current.exe')
            ..writeAsStringSync('original');
          final release = (await client.check('0.1.2')).release!;
          if (failure == 'http') status = 503;
          final broken = AppRelease(
            release.version,
            release.name,
            release.url,
            failure == 'checksum' ? '0' * 64 : release.sha256sum,
            release.size +
                (failure == 'truncated'
                    ? 1
                    : failure == 'oversized'
                    ? -1
                    : 0),
          );
          await expectLater(
            client.download(broken, dir, (_) {}),
            throwsA(anything),
          );
          expect(existing.readAsStringSync(), 'original');
          expect(dir.listSync().length, 1);
        },
      );
    }
  });
  test('production client rejects insecure or unrelated download hosts', () {
    final client = ReleaseClient();
    expect(client.allowed(Uri.parse('http://github.com/a')), false);
    expect(client.allowed(Uri.parse('https://github.com.evil.test/a')), false);
    expect(client.allowed(Uri.parse('https://user@github.com/a')), false);
    expect(
      client.allowed(
        Uri.parse('https://release-assets.githubusercontent.com/a'),
      ),
      true,
    );
  });
  group('installation staging', () {
    late Directory dir;
    late File old;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('howdoi-stage-');
      old = File('${dir.path}/current.exe')..writeAsStringSync('keep');
    });
    tearDown(() => dir.deleteSync(recursive: true));
    Map<String, String> package({
      String? badPath,
      String version = '0.1.3+4',
      bool missing = false,
    }) {
      final archive = Archive();
      for (final name in [
        'howdoi.exe',
        'flutter_windows.dll',
        'data/icudtl.dat',
        if (!missing) 'data/app.so',
        'data/flutter_assets/pubspec.yaml',
        ?badPath,
      ]) {
        final data = utf8.encode(
          name.endsWith('pubspec.yaml') ? 'version: $version\n' : 'fixture',
        );
        archive.add(ArchiveFile(name, data.length, data));
      }
      final bytes = ZipEncoder().encode(archive);
      final zip = File('${dir.path}/package.zip')..writeAsBytesSync(bytes);
      return {
        'archive': zip.path,
        'sha': sha256.convert(bytes).toString(),
        'root': '${dir.path}/versions',
        'version': '0.1.3',
      };
    }

    test('valid package is installed side by side', () async {
      final args = package();
      final exe = await stageRelease(args);
      expect(File(exe).readAsStringSync(), 'fixture');
      expect(old.readAsStringSync(), 'keep');
      expect(exe, startsWith('${dir.path}/versions/0.1.3-'));
    });
    for (final path in [
      '../escape',
      '/absolute',
      'C:/escape',
      'data/../../escape',
      'data/NUL.txt',
      'HOWDOI.EXE',
    ]) {
      test('reject $path without touching current installation', () async {
        await expectLater(
          stageRelease(package(badPath: path)),
          throwsFormatException,
        );
        expect(old.readAsStringSync(), 'keep');
        expect(Directory('${dir.path}/versions').existsSync(), false);
      });
    }
    test(
      'missing files, different version, changed bytes, invalid zip and unwritable destination',
      () async {
        await expectLater(
          stageRelease(package(missing: true)),
          throwsFormatException,
        );
        await expectLater(
          stageRelease(package(version: '0.2.0')),
          throwsFormatException,
        );
        final args = package();
        args['sha'] = '0' * 64;
        await expectLater(stageRelease(args), throwsFormatException);
        final invalid = utf8.encode('not a zip');
        File(args['archive']!).writeAsBytesSync(invalid);
        args['sha'] = sha256.convert(invalid).toString();
        await expectLater(stageRelease(args), throwsA(anything));
        final blocked = package();
        blocked['root'] = old.path;
        await expectLater(
          stageRelease(blocked),
          throwsA(isA<FileSystemException>()),
        );
        expect(old.readAsStringSync(), 'keep');
      },
    );
    test(
      'missing executable probe does not touch original or leave probe folder',
      () async {
        final backup = File('${dir.path}/backup.db')..writeAsStringSync('data');
        await expectLater(
          probeRelease('${dir.path}/missing.exe', backup.path, dir.path),
          throwsA(isA<ProcessException>()),
        );
        expect(backup.readAsStringSync(), 'data');
        expect(dir.listSync().whereType<Directory>(), isEmpty);
      },
    );
  });
}
