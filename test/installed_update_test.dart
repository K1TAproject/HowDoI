import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;
import 'v014_test.dart' show cost;

void main() {
  test(
    'isolated installed update and rollback preserve trips, preparations, budgets and settings',
    () async {
      tz.initializeTimeZones();
      final folder = Directory('work/installed-update-fixture').absolute
        ..createSync(recursive: true);
      final file = File(
        '${folder.path}/fixture-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final s = Store(file.path);
      final trip = s.save('trip', tripData());
      s.savePreparations(trip, [
        {'id': 'p', 'name': '护照', 'due': '', 'note': '已核对', 'done': true},
      ]);
      s.save('item', {
        ...itemData(trip.id, '飞行'),
        'costs': [cost('EUR', '12.34')],
      });
      s.setSetting('test-preference', 'retain');
      s.dispose();
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        'scripts/Test-InstalledUpdate.ps1',
        '-Database',
        file.path,
      ]);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      expect(result.exitCode, 0);
      final restored = Store(file.path);
      expect(
        restored.preparations(restored.trips.single).single['note'],
        '已核对',
      );
      expect(
        restored.items(trip.id).single.data['costs'][0]['amount'],
        '12.34',
      );
      expect(restored.setting('test-preference'), 'retain');
      restored.dispose();
    },
    skip: !const bool.fromEnvironment('HOWDOI_INSTALLER_SMOKE'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
