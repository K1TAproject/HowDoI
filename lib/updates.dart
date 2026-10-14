import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'model.dart';
import 'store.dart';

const releaseRepository = 'https://github.com/K1TAproject/HowDoI';
const releaseApi =
    'https://api.github.com/repos/K1TAproject/HowDoI/releases/latest';
String versionFromPubspec(String text) {
  final version = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+(?:\+\d+)?)\s*$',
    multiLine: true,
  ).firstMatch(text)?.group(1);
  if (version == null) throw const FormatException('版本信息缺失');
  return version;
}

Future<String> appVersion() async =>
    versionFromPubspec(await rootBundle.loadString('pubspec.yaml'));
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(v)) {
      throw const FormatException('发布版本格式无效');
    }
    final p = v.split(RegExp(r'[.+]')).map(int.parse).toList();
    return p.length == 3 ? [...p, 0] : p;
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 4; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

class AppRelease {
  final String version, name, sha256sum;
  final Uri url;
  final int size;
  AppRelease(this.version, this.name, this.url, this.sha256sum, this.size);
}

class UpdateCheck {
  final String message;
  final AppRelease? release;
  UpdateCheck(this.message, [this.release]);
}

class ReleaseClient {
  final Uri api;
  ReleaseClient({Uri? api}) : api = api ?? Uri.parse(releaseApi);
  bool allowed(Uri uri) {
    if (api.host == '127.0.0.1') {
      return uri.host == api.host &&
          uri.port == api.port &&
          uri.scheme == 'http';
    }
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        (uri.host == 'api.github.com' ||
            uri.host == 'github.com' ||
            uri.host == 'release-assets.githubusercontent.com' ||
            uri.host == 'objects.githubusercontent.com');
  }

  Future<HttpClientResponse> request(HttpClient client, Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!allowed(uri)) throw const FormatException('更新下载地址不受信任');
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'HowDoI-Windows-Updater');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await req.close().timeout(const Duration(seconds: 20));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) throw const FormatException('更新地址重定向无效');
        uri = uri.resolve(location);
      } else {
        return response;
      }
    }
    throw const FormatException('更新地址重定向过多');
  }

  Future<List<int>> readLimited(HttpClientResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('更新响应超过大小限制');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<UpdateCheck> check(String current) async {
    final client = HttpClient();
    try {
      final response = await request(client, api);
      if (response.statusCode == 404) {
        return UpdateCheck('未找到可访问的正式发布版本（GitHub 返回 404）。可能尚未发布，或仓库不可访问。');
      }
      if (response.statusCode != 200) {
        throw HttpException('检查更新失败：HTTP ${response.statusCode}，请稍后重试');
      }
      final raw = jsonDecode(
        utf8.decode(await readLimited(response, 2 * 1024 * 1024)),
      );
      if (raw is! Map ||
          raw['draft'] != false ||
          raw['prerelease'] != false ||
          raw['tag_name'] is! String ||
          raw['assets'] is! List) {
        throw const FormatException('正式发布信息无效');
      }
      final version = (raw['tag_name'] as String).replaceFirst(
        RegExp(r'^v'),
        '',
      );
      if (compareVersions(version, current) <= 0) {
        return UpdateCheck('没有更新版本。当前 $current，最新正式发布 $version。');
      }
      final name = 'HowDoI-${version.split('+').first}-windows-x64.zip';
      final asset = (raw['assets'] as List)
          .whereType<Map>()
          .where((a) => a['name'] == name)
          .firstOrNull;
      if (asset == null) {
        return UpdateCheck('发现 $version，但该发布尚未提供 Windows 安装包。');
      }
      final url = Uri.parse(asset['browser_download_url'] as String);
      if (!allowed(url) ||
          (api.host != '127.0.0.1' &&
              !url.toString().startsWith(
                '$releaseRepository/releases/download/',
              ))) {
        throw const FormatException('发布包地址无效');
      }
      final size = asset['size'];
      if (size is! int || size <= 0 || size > 512 * 1024 * 1024) {
        throw const FormatException('发布包大小无效');
      }
      var digest = (asset['digest'] as String? ?? '').replaceFirst(
        RegExp(r'^sha256:'),
        '',
      );
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
        final sums = (raw['assets'] as List)
            .whereType<Map>()
            .where((a) => a['name'] == 'SHA256SUMS.txt')
            .firstOrNull;
        if (sums == null) throw const FormatException('发布缺少 SHA-256 校验信息，不能安装');
        final sumsUrl = Uri.parse(sums['browser_download_url'] as String);
        if (api.host != '127.0.0.1' &&
            !sumsUrl.toString().startsWith(
              '$releaseRepository/releases/download/',
            )) {
          throw const FormatException('校验文件地址无效');
        }
        final checksumResponse = await request(client, sumsUrl);
        if (checksumResponse.statusCode != 200) {
          throw const HttpException('校验文件下载失败');
        }
        final text = utf8.decode(await readLimited(checksumResponse, 65536));
        final matches = const LineSplitter()
            .convert(text)
            .map(
              (line) =>
                  RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line),
            )
            .where((m) => m?.group(2) == name)
            .toList();
        if (matches.length != 1) throw const FormatException('校验文件中没有唯一匹配的安装包');
        digest = matches.single!.group(1)!;
      }
      return UpdateCheck(
        '发现新版本 $version',
        AppRelease(version, name, url, digest.toLowerCase(), size),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<File> download(
    AppRelease release,
    Directory folder,
    ValueChanged<double> progress,
  ) async {
    final client = HttpClient();
    final file = File('${folder.path}/package-${uuid.v4()}.zip');
    IOSink? sink;
    try {
      await folder.create(recursive: true);
      final response = await request(client, release.url);
      if (response.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${response.statusCode}');
      }
      sink = file.openWrite();
      var received = 0, reported = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > release.size) {
          throw const FormatException('下载包大小与发布信息不符');
        }
        sink.add(chunk);
        if (received - reported >= 256 * 1024) {
          reported = received;
          progress(received / release.size);
        }
      }
      await sink.close();
      sink = null;
      if (received != release.size) throw const FormatException('下载未完成，原版本未改变');
      if ((await sha256.bind(file.openRead()).first).toString() !=
          release.sha256sum) {
        throw const FormatException('SHA-256 校验失败，原版本未改变');
      }
      progress(1);
      return file;
    } catch (_) {
      await sink?.close();
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

// Extract only into a fresh private directory; the running installation is never overwritten.
Future<String> stageRelease(Map<String, String> args) async {
  compareVersions(args['version']!, '0.0.0');
  final bytes = await File(args['archive']!).readAsBytes();
  if (sha256.convert(bytes).toString() != args['sha']) {
    throw const FormatException('安装前校验失败');
  }
  final decoder = ZipDecoder();
  final archive = decoder.decodeBytes(bytes);
  final names = <String>{};
  var total = 0;
  for (final header in decoder.directory.fileHeaders) {
    final name = header.filename.replaceAll('\\', '/');
    final parts = name.split('/').where((p) => p.isNotEmpty).toList();
    if (name.startsWith('/') ||
        parts.isEmpty ||
        parts.any(
          (p) =>
              p == '.' ||
              p == '..' ||
              p.contains(':') ||
              p.contains('\u0000') ||
              p.endsWith('.') ||
              p.endsWith(' ') ||
              RegExp(
                r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                caseSensitive: false,
              ).hasMatch(p),
        ) ||
        !names.add(name.toLowerCase())) {
      throw const FormatException('安装包路径无效或重复');
    }
    total += header.uncompressedSize;
    if (total > 1024 * 1024 * 1024 || names.length > 20000) {
      throw const FormatException('解压大小超过限制');
    }
  }
  for (final file in archive) {
    if (file.isSymbolicLink) throw const FormatException('安装包不能包含符号链接');
  }
  for (final required in [
    'howdoi.exe',
    'flutter_windows.dll',
    'data/icudtl.dat',
    'data/app.so',
    'data/flutter_assets/pubspec.yaml',
  ]) {
    if (!names.contains(required)) throw FormatException('安装包缺少 $required');
  }
  final spec = archive.findFile('data/flutter_assets/pubspec.yaml');
  if (spec == null ||
      versionFromPubspec(utf8.decode(spec.content)).split('+').first !=
          args['version']!.split('+').first) {
    throw const FormatException('安装包内版本与发布版本不符');
  }
  final destination = Directory(
    '${args['root']}/${args['version']}-${uuid.v4()}',
  );
  await destination.create(recursive: true);
  try {
    for (final entry in archive) {
      final relative = entry.name.replaceAll('\\', '/');
      if (!entry.isFile) {
        await Directory(
          '${destination.path}/$relative',
        ).create(recursive: true);
        continue;
      }
      final output = File('${destination.path}/$relative');
      await output.parent.create(recursive: true);
      final content = entry.content;
      if (content.length != entry.size || getCrc32(content) != entry.crc32) {
        throw const FormatException('解压校验失败');
      }
      await output.writeAsBytes(content, flush: true);
    }
    return '${destination.path}/howdoi.exe';
  } catch (_) {
    // This is the unique directory created above, never the current installation or database.
    await destination.delete(recursive: true);
    rethrow;
  } finally {
    await archive.clear();
  }
}

// First launch uses a disposable database copy. No sync or real data is opened.
Future<void> probeRelease(String exe, String backup, String folder) async {
  final probe = await Directory(
    '$folder/probe-${uuid.v4()}',
  ).create(recursive: true);
  final database = await File(backup).copy('${probe.path}/howdoi.db');
  final ready = File('${probe.path}/ready');
  Process? process;
  try {
    process = await Process.start(exe, [
      '--update-probe',
      database.path,
      ready.path,
    ], workingDirectory: File(exe).parent.path);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final code = await process.exitCode.timeout(const Duration(seconds: 30));
    if (code != 0 || !await ready.exists()) {
      throw StateError('新版试启动失败（$code），未打开现有旅行数据');
    }
  } finally {
    process?.kill();
    if (process != null) await process.exitCode;
    await probe.delete(recursive: true);
  }
}

class UpdateDialog extends StatefulWidget {
  final Store store;
  const UpdateDialog({super.key, required this.store});
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  String version = '', status = '读取版本信息…';
  AppRelease? release;
  bool busy = false;
  double? progress;
  @override
  void initState() {
    super.initState();
    appVersion()
        .then((v) {
          if (mounted) {
            setState(() {
              version = v;
              status = '点击“检查更新”连接 GitHub Releases';
            });
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => status = '$e');
        });
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      release = null;
      status = '正在检查正式发布版本…';
    });
    try {
      final result = await ReleaseClient().check(version);
      if (mounted) {
        setState(() {
          status = result.message;
          release = result.release;
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = '检查失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    final selected = release!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('安装 ${selected.version}？'),
        content: const Text(
          '下载并校验后，将备份旅行数据，安装到独立版本目录并启动新版。原程序保留；下载或安装失败不会替换原程序。新版启动成功后当前窗口关闭。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认下载并安装'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      busy = true;
      status = '正在下载…';
      progress = 0;
    });
    try {
      final support = await getApplicationSupportDirectory();
      final folder = Directory('${support.path}/updates');
      final file = await ReleaseClient().download(selected, folder, (v) {
        if (mounted) setState(() => progress = v);
      });
      if (mounted) {
        setState(() {
          status = '校验通过，准备安装…';
          progress = null;
        });
      }
      final exe = await compute(stageRelease, {
        'archive': file.path,
        'sha': selected.sha256sum,
        'root': '${folder.path}/versions',
        'version': selected.version,
      });
      final backup =
          '${folder.path}/before-${selected.version}-${DateTime.now().microsecondsSinceEpoch}.db';
      widget.store.snapshot(backup);
      if (mounted) setState(() => status = '使用数据副本验证新版能否启动…');
      await probeRelease(exe, backup, folder.path);
      final ready = File('${folder.path}/ready-${uuid.v4()}');
      Process? process;
      try {
        process = await Process.start(exe, [
          '--update-ready',
          ready.path,
        ], workingDirectory: File(exe).parent.path);
        process.stdout.drain<void>();
        process.stderr.drain<void>();
        int? exitCode;
        unawaited(process.exitCode.then((v) => exitCode = v));
        for (
          var i = 0;
          i < 300 && exitCode == null && !await ready.exists();
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (exitCode != null || !await ready.exists()) {
          throw StateError('新版未能完成启动，当前版本仍可使用。数据快照：$backup');
        }
        // A local launcher keeps the new version accessible without replacing a portable user's original files.
        await File('${folder.path}/启动已安装版本.cmd').writeAsString(
          '@echo off\r\nstart "" "${exe.replaceAll('%', '%%')}"\r\n',
          encoding: systemEncoding,
        );
        widget.store.setSetting('installedUpdate', exe);
        await ready.delete();
      } catch (_) {
        process?.kill();
        if (process != null) await process.exitCode;
        widget.store.restoreSnapshot(backup);
        rethrow;
      }
      // Open the install folder so a portable user can pin or create a shortcut to it.
      unawaited(
        Process.run('explorer.exe', [
          File(exe).parent.path,
        ]).then<void>((_) {}, onError: (Object _) {}),
      );
      exit(0);
    } catch (e) {
      if (mounted) setState(() => status = '更新未完成：$e\n当前程序保留，可重试。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('关于 HowDoI · 检查更新'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前版本：${version.isEmpty ? '读取中' : version}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const SelectableText(releaseRepository),
              const SizedBox(height: 16),
              Text(status),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(value: progress),
                ),
              if (widget.store.setting('installedUpdate') != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    '已安装版本位置：${widget.store.setting('installedUpdate')}',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        OutlinedButton(
          onPressed: busy || version.isEmpty ? null : check,
          child: const Text('检查更新'),
        ),
        if (release != null)
          FilledButton(
            onPressed: busy || !Platform.isWindows ? null : install,
            child: const Text('下载并安装'),
          ),
      ],
    ),
  );
}
