import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/store.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/planner.dart';
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(tz.initializeTimeZones);
  late Store store;
  late Record trip;
  setUp(() {
    store = Store(':memory:');
    trip = store.save('trip', tripData());
  });
  tearDown(() => store.dispose());
  test(
    'blank deletion preserves gaps; undo restores; stale undo is rejected',
    () {
      store.addDay(trip);
      store.addDay(trip);
      store.addDay(trip);
      store.changeDay(trip, 2, expectedGeneration: store.generation);
      final removed = store.get('day:${trip.id}:2')!;
      expect(store.visibleDays(trip.id), [1, 3]);
      expect(dayDate(trip.data, 3), '2026-10-13');
      store.undoEmptyDay(removed);
      expect(store.visibleDays(trip.id), [1, 2, 3]);
      expect(() => store.undoEmptyDay(removed), throwsFormatException);
    },
  );
  test(
    'move merges timed groups, preserves budget, ticket dates and other days',
    () {
      final early = store.save('item', {
        ...itemData(trip.id, '先到'),
        'fields': {'startTime': '08:00'},
      });
      final untimed = store.save('item', itemData(trip.id, '随后'));
      store.reorder(trip.id, 1, [early.id, untimed.id]);
      final booked = store.save('item', {
        ...itemData(trip.id, '航班', type: '航班'),
        'endDay': 2,
        'booking': '已预订',
        'fields': {
          'startTime': '09:37',
          'endTime': '01:20',
          'startDate': '2026-10-11',
          'endDate': '2026-10-12',
        },
        'costs': [
          {
            'id': 'c',
            'label': '',
            'currency': 'EUR',
            'amount': '100',
            'category': '交通',
          },
        ],
      });
      final target = store.save('item', {
        ...itemData(trip.id, '目的日', day: 4),
        'fields': {'startTime': '10:00'},
      });
      final other = store.save('item', itemData(trip.id, '不改变', day: 9));
      final budget = Budget(trip, store.items(trip.id)).byCurrency;
      store.changeDay(trip, 1, target: 4, expectedGeneration: store.generation);
      expect(store.timeline(trip.id, 4).map((n) => n.id), [
        early.id,
        untimed.id,
        booked.id,
        target.id,
      ]);
      expect(store.get(booked.id)!.data['endDay'], 5);
      expect(store.get(booked.id)!.data['fields'], booked.data['fields']);
      expect(dateWarning(trip, store.get(booked.id)!.data), contains('请确认'));
      expect(store.get(other.id)!.toJson(), other.toJson());
      expect(Budget(trip, store.items(trip.id)).byCurrency, budget);
      expect(store.visibleDays(trip.id), [4, 5, 9]);
      final copy = Store(':memory:');
      copy.importCopy(decodeRecords(store.export()));
      expect(copy.visibleDays(copy.trips.single.id), [4, 5, 9]);
      copy.dispose();
    },
  );
  test(
    'hotel coverage and cross-day arrival are not empty and cannot be deleted',
    () {
      final hotel = store.save('item', itemData(trip.id, '连住', type: '住宿'));
      final flight = store.save('item', {
        ...itemData(trip.id, '夜航', type: '航班'),
        'endDay': 2,
      });
      expect(store.primaryItems(trip.id, 2), isEmpty);
      expect(store.relatedItems(trip.id, 2).map((r) => r.id).toSet(), {
        hotel.id,
        flight.id,
      });
      final before = store.export();
      expect(
        () => store.changeDay(
          trip,
          2,
          deleteItems: true,
          expectedGeneration: store.generation,
        ),
        throwsFormatException,
      );
      expect(store.export(), before);
      store.changeDay(trip, 1, target: 4, expectedGeneration: store.generation);
      expect(store.get(hotel.id)!.data['endDay'], 6);
      expect(store.visibleDays(trip.id), [4, 5]);
    },
  );
  test(
    'invalid shift and stale preview are atomic; confirmed deletion tombstones only primary items',
    () {
      final hotel = store.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿'),
        'endDay': 3660,
      });
      final before = store.export();
      expect(
        () => store.changeDay(
          trip,
          1,
          target: 3,
          expectedGeneration: store.generation,
        ),
        throwsFormatException,
      );
      expect(store.export(), before);
      final preview = store.generation;
      final other = store.save('item', itemData(trip.id, '其他', day: 3660));
      expect(
        () => store.changeDay(trip, 1, target: 2, expectedGeneration: preview),
        throwsFormatException,
      );
      store.changeDay(
        trip,
        1,
        deleteItems: true,
        expectedGeneration: store.generation,
      );
      expect(store.get(hotel.id)!.deleted, true);
      expect(store.get(other.id)!.deleted, false);
      expect(store.visibleDays(trip.id), [3660]);
    },
  );
  test(
    'unbooked fields move by delta without changing other dates; cross-year labels',
    () {
      final item = store.save('item', {
        ...itemData(trip.id, '预约'),
        'fields': {
          'startDate': '2026-10-11',
          'endDate': '2026-10-11',
          'reservationDate': '2026-10-12',
        },
      });
      store.changeDay(trip, 1, target: 3, expectedGeneration: store.generation);
      expect(store.get(item.id)!.data['fields'], {
        'startDate': '2026-10-13',
        'endDate': '2026-10-13',
        'reservationDate': '2026-10-14',
      });
      trip = store.save('trip', {
        ...trip.data,
        'start': '2026-12-31',
      }, id: trip.id);
      expect(dayTitle(trip, 2), '1月1日 · 周五');
      expect(daySubtitle(trip, 2), '第 2 天 · 2027年');
    },
  );
}
