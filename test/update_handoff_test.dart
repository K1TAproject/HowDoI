import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production handoff starts helper before closing parent and snapshots data',
    () async {
      final dir = Directory.systemTemp.createTempSync('howdoi-handoff-');
      final helper = await writeUpdateHelper(dir);
      final pidFile = File('${dir.path}/helper-pid');
      final source = await helper.readAsString();
      await helper.writeAsString(
        '\ufeff${source.replaceFirst("\$ErrorActionPreference = 'Stop'", "[IO.File]::WriteAllText('${pidFile.path}', [string]\$PID)\n\$ErrorActionPreference = 'Stop'")}',
      );
      final store = Store('${dir.path}/data.db');
      store.setSetting('fixture', 'keep');
      try {
        await handOffInstaller(
          folder: dir,
          helper: helper,
          package: File('${dir.path}/never-run.exe'),
          release: AppRelease(
            '0.1.8',
            'fixture',
            Uri.parse('https://example.invalid'),
            '0' * 64,
            0,
          ),
          target: '${dir.path}/unused-install',
          store: store,
        );
        final status = jsonDecode(
          File('${dir.path}/installer-result.json').readAsStringSync(),
        );
        expect(status['state'], 'waiting');
        expect(store.setting('fixture'), 'keep');
        expect(
          dir.listSync().whereType<File>().where(
            (f) => f.path.contains('before-'),
          ),
          hasLength(1),
        );
        expect(Directory('${dir.path}/unused-install').existsSync(), false);
      } finally {
        if (pidFile.existsSync()) {
          Process.killPid(int.parse(pidFile.readAsStringSync()));
        }
        store.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        dir.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'helper survives parent exit and proceeds only after readiness handoff',
    () async {
      final dir = Directory.systemTemp.createTempSync('howdoi-parent-exit-');
      final helper = await writeUpdateHelper(dir);
      // Exercise the real launch/wait path, stopping at the installation boundary.
      // Actual installation/rollback is covered by installed_update_test.dart.
      final source = (await helper.readAsString()).replaceFirst(
        RegExp(r'        \$exe = Invoke-InstallerUpdate[^\r\n]+'),
        "        Write-UpdateStatus \$jobData 'completed' 'Parent exited; installer boundary reached'; exit 0",
      );
      await helper.writeAsString('\ufeff$source');
      final parent = File('${dir.path}/parent.dart');
      await parent.writeAsString('''
import 'dart:io';
import 'dart:convert';
Future<void> main(List<String> args) async {
  final folder = args[0];
  final job = File('\$folder/job.json');
  await job.writeAsString(jsonEncode({'parentId': pid, 'ready': '\$folder/ready',
    'result': '\$folder/result.json', 'target': '\$folder/unused', 'version': 'test'}));
  final p = await Process.start('powershell.exe', ['-NoProfile', '-NonInteractive',
    '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', args[1], '-Job', job.path]);
  await p.stdin.close();
  p.stdout.drain<void>(); p.stderr.drain<void>();
  for (var i = 0; i < 100; i++) {
    if (File('\$folder/ready').existsSync()) exit(0);
    await Future<void>.delayed(Duration(milliseconds: 100));
  }
  p.kill(); exit(1);
}
''');
      try {
        final result = await Process.run(
          '.tools/flutter/bin/cache/dart-sdk/bin/dart.exe',
          [parent.path, dir.path, helper.path],
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final status = File('${dir.path}/result.json');
        for (var i = 0; i < 100; i++) {
          if (status.existsSync() &&
              status.readAsStringSync().contains('completed')) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(jsonDecode(status.readAsStringSync())['state'], 'completed');
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
