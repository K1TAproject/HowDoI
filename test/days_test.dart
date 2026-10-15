import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/store.dart';
import 'package:howdoi/model.dart';
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'failed update can transactionally restore records and settings from snapshot',
    () {
      final dir = Directory.systemTemp.createTempSync('howdoi-rollback-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store('${dir.path}/test.db');
      final trip = store.save('trip', tripData());
      store.addDay(trip);
      store.setSetting('custom', 'before');
      final original = store.export();
      final backup = '${dir.path}/snapshot.db';
      store.snapshot(backup);
      store.remove(trip);
      store.setSetting('custom', 'changed');
      store.restoreSnapshot(backup);
      expect(store.export(), original);
      expect(store.setting('custom'), 'before');
      expect(store.visibleDays(trip.id), [1]);
      store.dispose();
    },
  );
  test(
    'explicit blank days persist, append after latest, export/import and survive deleting items',
    () {
      final dir = Directory.systemTemp.createTempSync('howdoi-days-');
      addTearDown(() => dir.deleteSync(recursive: true));
      var store = Store('${dir.path}/test.db');
      final trip = store.save('trip', tripData());
      expect(store.visibleDays(trip.id), isEmpty);
      expect(store.addDay(trip), 1);
      expect(store.items(trip.id), isEmpty);
      expect(dayDate(trip.data, 1), '2026-10-11');
      final item = store.save('item', itemData(trip.id, '第5天景点', day: 5));
      expect(store.visibleDays(trip.id), [1, 5]);
      expect(store.addDay(trip), 6);
      store.remove(item);
      expect(store.visibleDays(trip.id), [1, 6]);
      store.dispose();
      store = Store('${dir.path}/test.db');
      expect(store.visibleDays(trip.id), [1, 6]);
      final copy = Store(':memory:');
      copy.importCopy(decodeRecords(store.export()));
      expect(copy.visibleDays(copy.trips.single.id), [1, 6]);
      expect(copy.addDay(copy.trips.single), 7);
      copy.dispose();
      store.dispose();
    },
  );
  test(
    'legacy formats retain undated records; allocation preserves details and budget',
    () {
      final store = Store(':memory:');
      addTearDown(store.dispose);
      final trip = store.save('trip', {...tripData(), 'start': ''});
      final item = store.save('item', {
        ...itemData(trip.id, '历史酒店', type: '住宿', day: 0),
        'fields': {'custom': '保留', 'seat': '8A'},
        'costs': [
          {
            'id': 'cost',
            'label': '',
            'category': '住宿',
            'currency': 'EUR',
            'amount': '100',
          },
        ],
      });
      final old = jsonDecode(store.export()) as Map;
      for (final version in [1, 2, 3]) {
        old['version'] = version;
        expect(
          decodeRecords(jsonEncode(old)).any((r) => r.id == item.id),
          true,
        );
      }
      final budget = Budget(trip, store.items(trip.id)).byCurrency;
      expect(() => store.assignDay(item, 5), throwsFormatException);
      store.assignDay(item, 5, endDay: 7);
      final changed = store.get(item.id)!;
      expect(changed.data['day'], 5);
      expect(changed.data['fields'], item.data['fields']);
      expect(changed.data['costs'], item.data['costs']);
      expect(Budget(trip, store.items(trip.id)).byCurrency, budget);
      expect(store.visibleDays(trip.id), [5, 6]);
      expect(dayDate(trip.data, 5), '');
      expect(() => store.assignDay(item, 6), throwsFormatException);
    },
  );
}
