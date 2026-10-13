import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/model.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'existing database gets one upgrade snapshot and keeps legacy fields',
    () {
      final dir = Directory.systemTemp.createTempSync('howdoi-upgrade-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/howdoi.db';
      var s = Store(path);
      final t = s.save('trip', tripData());
      final item = s.save('item', {
        ...itemData(t.id, '旧行程', type: '自驾'),
        'fields': {'distance': '88', 'custom': '保留'},
      });
      s.db.execute("DELETE FROM settings WHERE key='dataVersion'");
      s.dispose();
      s = Store(path);
      final backup = s.setting('upgradeBackup')!;
      expect(File(backup).existsSync(), true);
      expect(File(backup).lengthSync(), greaterThan(0));
      expect(s.get(item.id)!.data['fields']['custom'], '保留');
      expect(itemType(s.get(item.id)!.data), '交通/移动');
      s.dispose();
      s = Store(path);
      expect(s.setting('upgradeBackup'), backup);
      expect(dir.listSync().where((f) => f.path.contains('.pre-')).length, 1);
      s.dispose();
    },
  );
  test(
    'timed anchors carry untimed blocks; deleting/moving never carries them across days',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', tripData());
      Record add(String name, String time) => s.save('item', {
        ...itemData(trip.id, name),
        'fields': {'startTime': time},
      });
      final lunch = add('午餐', '12:00'),
          shopping = add('购物', ''),
          museum = add('博物馆', '15:00');
      s.reorder(trip.id, 1, [lunch.id, shopping.id, museum.id]);
      s.save('item', {
        ...lunch.data,
        'fields': {'startTime': '16:00'},
      }, id: lunch.id);
      expect(s.timeline(trip.id, 1).map((n) => n.item.id), [
        museum.id,
        lunch.id,
        shopping.id,
      ]);
      s.save('item', {
        ...s.get(lunch.id)!.data,
        'day': 3,
        'endDay': 3,
      }, id: lunch.id);
      expect(s.timeline(trip.id, 1).map((n) => n.item.id), [
        museum.id,
        shopping.id,
      ]);
      s.remove(museum);
      expect(s.timeline(trip.id, 1).single.item.id, shopping.id);
      expect(s.get(shopping.id)!.data['day'], 1);
      expect(fieldText(s.get(shopping.id)!.data, 'startTime'), '');
    },
  );
  test(
    'sparse dates, hotel exclusive checkout, arrival and rental projections count budget once',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final t = s.save('trip', tripData());
      final hotel = s.save('item', {
        ...itemData(t.id, '酒店', type: '住宿'),
        'endDay': 4,
      });
      expect(s.visibleDays(t.id), [1, 2, 3]);
      expect(s.timeline(t.id, 1), isEmpty);
      expect(s.timeline(t.id, 4), isEmpty);
      s.save('item', {
        ...hotel.data,
        'fields': {'endTime': '11:00'},
      }, id: hotel.id);
      expect(s.timeline(t.id, 4).single.prefix, '退房 · ');
      s.remove(s.get(hotel.id)!);
      final flight = s.save('item', {
        ...itemData(t.id, '', type: '航班'),
        'endDay': 3,
        'fields': {
          'origin': '上海浦东',
          'destination': '赫尔辛基',
          'number': 'AY88',
          'endTime': '06:00',
        },
      });
      expect(s.visibleDays(t.id), [1, 3]);
      expect(s.timeline(t.id, 3).single.item.id, flight.id);
      expect(itemTitle(flight.data), '上海浦东 → 赫尔辛基');
      final rental = s.save('item', {
        ...itemData(t.id, '', type: '租车', day: 3),
        'endDay': 6,
      });
      expect(s.visibleDays(t.id), [1, 3, 6]);
      expect(s.timeline(t.id, 6).single.item.id, rental.id);
      expect(Budget(t, s.items(t.id)).unknown, 2);
      final copy = Store(':memory:');
      addTearDown(copy.dispose);
      copy.importCopy(decodeRecords(s.export()));
      expect(copy.visibleDays(copy.trips.single.id), [1, 3, 6]);
      final orderIds = copy.all
          .where((r) => r.kind == 'order')
          .expand((r) => r.data['ids'] as List);
      expect(orderIds.any((id) => id.toString().contains(flight.id)), false);
    },
  );
  test(
    'legacy data survives; departure changes preserve booked dates and shift drafts',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final t = s.save('trip', tripData());
      final legacy = {
        ...itemData(t.id, '', type: '航班'),
        'fields': {
          'startDate': '2026-10-11',
          'startTime': '02:00',
          'startZone': 'Asia/Shanghai',
          'seat': '8A',
        },
      };
      final booked = s.save('item', {...legacy, 'booking': '已预订'});
      final draft = s.save('item', legacy);
      final changed = s.save('trip', {
        ...t.data,
        'start': '2026-11-01',
      }, id: t.id);
      expect(fieldText(s.get(booked.id)!.data, 'startDate'), '2026-10-11');
      expect(fieldText(s.get(draft.id)!.data, 'startDate'), '2026-11-01');
      expect(fieldText(s.get(booked.id)!.data, 'seat'), '8A');
      expect(fieldText(s.get(booked.id)!.data, 'startTime'), '02:00');
      expect(dateWarning(changed, s.get(booked.id)!.data), contains('固定日期'));
      final envelope = jsonDecode(s.export()) as Map<String, dynamic>;
      envelope['version'] = 1;
      expect(
        decodeRecords(jsonEncode(envelope)).length,
        s.all.where((r) => !r.deleted).length,
      );
      envelope['format'] = 'howdoi-sync';
      expect(
        () => decodeRecords(jsonEncode(envelope), format: 'howdoi-sync'),
        throwsFormatException,
      );
    },
  );
  test('appointment is a sorting time without inventing planned start', () {
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final t = s.save('trip', tripData());
    final item = s.save('item', {
      ...itemData(t.id, ''),
      'fields': {'reservationTime': '10:15'},
    });
    expect(s.timeline(t.id, 1).single.time, '10:15');
    expect(s.timeline(t.id, 1).single.appointment, true);
    expect(fieldText(item.data, 'startTime'), '');
  });
}
