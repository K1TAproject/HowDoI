// Opt-in: requires a freshly built Windows package and real network access.
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/updates.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;

void main() {
  const runSmoke = bool.fromEnvironment('HOWDOI_RELEASE_SMOKE');
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real GitHub latest release response', () async {
    HttpOverrides.global = null;
    final result = await ReleaseClient().check(await appVersion());
    // This is a real response, never a forced simulated update result.
    // ignore: avoid_print
    print('GitHub check: ${result.message}');
    expect(result.message, isNotEmpty);
  }, skip: !runSmoke);
  test(
    'actual packaged executable stages and boots with a data copy; invalid database fails safely',
    () async {
      tz.initializeTimeZones();
      final version = (await appVersion()).split('+').first;
      final zip = File('dist/HowDoI-$version-windows-x64.zip');
      final dir = Directory.systemTemp.createTempSync('howdoi-release-smoke-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store('${dir.path}/original.db');
      final trip = store.save('trip', tripData());
      store.save('item', itemData(trip.id, '发布包试启动验证'));
      store.addDay(trip);
      final data = store.export();
      final backup = '${dir.path}/snapshot.db';
      store.snapshot(backup);
      final originalHash = sha256.convert(File(backup).readAsBytesSync());
      final exe = await stageRelease({
        'archive': zip.path,
        'sha': (await sha256.bind(zip.openRead()).first).toString(),
        'root': '${dir.path}/versions',
        'version': version,
      });
      await probeRelease(exe, backup, dir.path);
      expect(store.export(), data);
      expect(sha256.convert(File(backup).readAsBytesSync()), originalHash);
      final broken = File('${dir.path}/invalid.db')
        ..writeAsStringSync('invalid database');
      await expectLater(
        probeRelease(exe, broken.path, dir.path),
        throwsStateError,
      );
      expect(store.export(), data);
      // ignore: avoid_print
      print(
        'Packaged $version: successful startup acknowledgement; invalid database rejected; original data unchanged.',
      );
      store.dispose();
    },
    skip: !runSmoke || !Platform.isWindows,
  );
}
