import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/overview.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/editors.dart';
import 'core_test.dart' show tripData, itemData;
import 'v014_test.dart' show cost;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'overview preserves gaps, cross-day order, repeated visits, original budgets and backups',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', {...tripData(), 'start': ''});
      final flight = s.save('item', {
        ...itemData(trip.id, '', type: '航班'),
        'endDay': 2,
        'fields': {
          'origin': 'A',
          'destination': 'B',
          'number': 'XY123',
          'startTime': '22:00',
          'endTime': '05:00',
        },
        'costs': [cost('CNY', '100')],
      });
      final hotel = s.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿', day: 2),
        'endDay': 5,
        'fields': {'startTime': '15:00'},
        'costs': [
          cost('EUR', '200', category: '住宿'),
          cost('EUR', '', category: '住宿'),
        ],
      });
      s.save('item', {
        ...itemData(trip.id, '', type: '铁路', day: 6),
        'fields': {'origin': 'B', 'destination': 'A'},
        'costs': [cost('JPY', '0')],
      });
      s.save('item', {
        ...itemData(trip.id, '再访', day: 6),
        'fields': {'address': 'A'},
      });
      s.save('item', {
        ...itemData(trip.id, '历史', day: 0),
        'costs': [cost('CNY', '25'), cost('USD', '')],
      });
      s.save('day', {
        'trip': trip.id,
        'day': 8,
        'zone': 'Asia/Shanghai',
        'explicit': true,
      });
      final before = s.export(), generation = s.generation;
      final data = TripOverviewData(s, trip);
      expect(data.days, [1, 2, 3, 4, 6, 8]);
      expect(data.span, 8);
      expect(data.plannedDays, 5);
      expect(data.range, '第 1 天 至 第 8 天');
      expect(data.byDay[2]!.where((n) => n.item.id == hotel.id).length, 1);
      expect(data.byDay[2]!.map((n) => n.id), contains('${flight.id}@end'));
      expect(
        [
          for (final d in data.days)
            for (final n in data.route(d)) ...data.places(n),
        ],
        ['A', 'B', '酒店', 'B', 'A', 'A'],
      );
      expect(data.placeNames, {'A', 'B', '酒店'});
      final stayOnly = Store(':memory:');
      addTearDown(stayOnly.dispose);
      final stayTrip = stayOnly.save('trip', tripData());
      stayOnly.save('item', itemData(stayTrip.id, '住宿', type: '住宿'));
      final stayData = TripOverviewData(stayOnly, stayTrip);
      expect(stayData.days, [1, 2]);
      expect(stayData.span, 3);
      expect(data.budget.byCurrency, {
        'CNY': BigInt.from(12500),
        'EUR': BigInt.from(20000),
        'JPY': BigInt.zero,
      });
      expect(data.budget.byCurrency, Budget(trip, s.items(trip.id)).byCurrency);
      expect(data.unknownCosts, 2);
      expect(data.noBudgetItems, 1);
      expect(s.export(), before);
      expect(s.generation, generation);
      s.save('item', {...flight.data, 'done': true}, id: flight.id);
      expect(
        TripOverviewData(s, trip).budget.byCurrency,
        data.budget.byCurrency,
      );
      final restored = Store(':memory:');
      addTearDown(restored.dispose);
      restored.importCopy(decodeRecords(s.export()));
      expect(
        TripOverviewData(restored, restored.trips.single).budget.byCurrency,
        data.budget.byCurrency,
      );
    },
  );
  test(
    'empty trip, date range across year, rental return and larger lists',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      var trip = s.save('trip', {...tripData(), 'start': '2026-12-31'});
      var data = TripOverviewData(s, trip);
      expect(data.span, 0);
      expect(data.budget.byCurrency, isEmpty);
      expect(data.placeNames, isEmpty);
      s.save('item', {
        ...itemData(trip.id, '', type: '租车'),
        'fields': {'origin': '取车处', 'destination': '还车处'},
      });
      for (var i = 0; i < 120; i++) {
        s.save('item', itemData(trip.id, '活动 $i', day: 2));
      }
      data = TripOverviewData(s, trip);
      expect(data.range, contains('2027-01-01'));
      expect(data.items.length, 121);
      expect(data.route(1).expand(data.places), ['取车处', '还车处']);
      expect(
        data.byDay[2]!.map((n) => n.id),
        s.timeline(trip.id, 2).map((n) => n.id),
      );
    },
  );
  testWidgets('empty and larger overview does not create days or overflow', (
    t,
  ) async {
    t.view.physicalSize = const Size(700, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final trip = s.save('trip', {...tripData(), 'start': ''});
    var selected = 0;
    Widget page() => MaterialApp(
      home: Scaffold(
        body: TripOverview(
          store: s,
          trip: trip,
          onDay: (d) => selected = d,
          onItem: (_) {},
        ),
      ),
    );
    await t.pumpWidget(page());
    await t.pumpAndSettle();
    expect(find.text('旅行跨度 0 天'), findsOneWidget);
    expect(s.visibleDays(trip.id), isEmpty);
    for (var i = 0; i < 150; i++) {
      s.save('item', itemData(trip.id, '记录 $i', day: 1 + i % 10));
    }
    final before = s.export();
    await t.pumpWidget(page());
    await t.pumpAndSettle();
    final button = find.widgetWithText(TextButton, '第 10 天');
    await t.scrollUntilVisible(button, 300);
    await t.tap(button);
    await t.pumpAndSettle();
    expect(selected, 10);
    expect(s.export(), before);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'overview expansion state cannot collide with saved scroll offset',
    (t) async {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', tripData());
      for (var i = 0; i < 25; i++) {
        s.save('item', {
          ...itemData(trip.id, '地点 $i'),
          'fields': {'address': '地址 $i'},
          'costs': [cost('EUR', '1')],
        });
      }
      final bucket = PageStorageBucket();
      Widget page() => MaterialApp(
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: TripOverview(
              store: s,
              trip: trip,
              onDay: (_) {},
              onItem: (_) {},
            ),
          ),
        ),
      );
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView).first, const Offset(0, -900));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.textContaining('地点清单 ·'), 300);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.textContaining('地点清单 ·'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('EUR 25.00'), 300);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final width in [1440.0, 700.0]) {
    testWidgets(
      'overview budget drilldown, refresh, navigation and dirty protection $width',
      (t) async {
        t.view.physicalSize = Size(width, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final sync = SyncService(s, host: true);
        final trip = s.save('trip', tripData());
        final r = s.save('item', {
          ...itemData(trip.id, '博物馆'),
          'costs': [
            cost('EUR', '30', category: '门票/活动'),
            cost('EUR', '10', category: '餐饮'),
            cost('JPY', '0'),
            cost('USD', ''),
          ],
        });
        await t.pumpWidget(HowDoI(store: s, sync: sync));
        await t.pumpAndSettle();
        if (width < 800) {
          await t.tap(find.byIcon(Icons.menu));
          await t.pumpAndSettle();
        }
        await t.tap(find.text('旅行总览'));
        await t.pumpAndSettle();
        if (width < 800) {
          expect(find.byType(Drawer), findsNothing);
        }
        expect(find.text('旅行跨度 1 天'), findsOneWidget);
        await t.scrollUntilVisible(
          find.text('EUR 40.00'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await t.pumpAndSettle();
        expect(find.text('门票/活动 · EUR 30.00 · 75.0%'), findsOneWidget);
        await t.tap(find.text('门票/活动 · EUR 30.00 · 75.0%'));
        await t.pumpAndSettle();
        await t.tap(find.text('未命名费用 · EUR 30.00'));
        await t.pumpAndSettle();
        expect(find.byType(ItemEditor), findsOneWidget);
        final fields = find.descendant(
          of: find.byType(ItemEditor),
          matching: find.byType(TextField),
        );
        await t.enterText(fields.first, '更新名称');
        await t.tap(find.byTooltip('关闭'));
        await t.pumpAndSettle();
        expect(find.text('尚未保存的修改'), findsOneWidget);
        await t.tap(find.text('保存'));
        await t.pumpAndSettle();
        expect(s.get(r.id)!.data['name'], '更新名称');
        expect(find.byType(TripOverview), findsOneWidget);
        s.save('item', {
          ...s.get(r.id)!.data,
          'costs': [cost('EUR', '50')],
        }, id: r.id);
        await t.pumpAndSettle();
        await t.scrollUntilVisible(
          find.text('EUR 50.00'),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await t.pumpAndSettle();
        expect(find.text('EUR 50.00'), findsOneWidget);
        final dayButton = find.widgetWithText(TextButton, dayTitle(trip, 1));
        await t.scrollUntilVisible(
          dayButton,
          -300,
          scrollable: find.byType(Scrollable).last,
        );
        await t.pumpAndSettle();
        Focus.of(
          t.element(
            find.descendant(
              of: dayButton,
              matching: find.text(dayTitle(trip, 1)),
            ),
          ),
        ).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(find.byType(TripOverview), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        sync.dispose();
        s.dispose();
      },
    );
  }
}
