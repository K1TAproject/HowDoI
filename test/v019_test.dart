import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/editors.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/overview.dart';
import 'package:howdoi/planner.dart';
import 'core_test.dart' show itemData, tripData;
import 'shared_places014_test.dart' show reach;

void main() {
  setUpAll(tz.initializeTimeZones);
  test('all existing types map only to existing categories', () {
    for (final type in [
      '航班',
      '铁路',
      '交通/移动',
      '市内交通',
      '长途汽车',
      '轮渡',
      '自驾',
      '租车',
      '出租车',
    ]) {
      expect(defaultBudgetCategory(type), '交通');
    }
    for (final type in ['住宿', '餐饮', '购物', '其他']) {
      expect(defaultBudgetCategory(type), type);
    }
    for (final type in ['游览', '游览/活动']) {
      expect(defaultBudgetCategory(type), '门票/活动');
    }
    expect(defaultBudgetCategory('未知'), '其他');
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'current type drives untouched placeholder, never edited rows $platform',
      (t) async {
        t.view.physicalSize = const Size(430, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        s.save('item', itemData(trip.id, '最多类型', type: '航班'));
        final key = GlobalKey<ItemEditorState>();
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: ItemEditor(
                key: key,
                store: s,
                trip: trip,
                day: 1,
                onClose: () {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        void type(String v) => t
            .widget<PopupMenuButton<String>>(
              find.byWidgetPredicate(
                (w) => w is PopupMenuButton<String> && w.tooltip == '选择活动类型',
              ),
            )
            .onSelected!(v);
        expect(key.currentState!.costRows.single['category'], '交通');
        type('餐饮');
        await t.pumpAndSettle();
        expect(key.currentState!.costRows.single['category'], '餐饮');
        await reach(t, find.text('预计预算'));
        await t.tap(find.text('预计预算'));
        await t.pumpAndSettle();
        expect(key.currentState!.value()['costs'], isEmpty);
        await reach(
          t,
          find.widgetWithText(DropdownButtonFormField<dynamic>, '分类'),
        );
        final cat = find.widgetWithText(DropdownButtonFormField<dynamic>, '分类');
        t.widget<DropdownButtonFormField<dynamic>>(cat).onChanged!('购物');
        await t.pumpAndSettle();
        // The selector can be outside the current viewport; its callback is the same saved-draft action.
        final selector = find.byWidgetPredicate(
          (w) => w is PopupMenuButton<String> && w.tooltip == '选择活动类型',
          skipOffstage: false,
        );
        final scroll = t
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ItemEditor),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        scroll.jumpTo(0);
        await t.pumpAndSettle();
        t.widget<PopupMenuButton<String>>(selector).onSelected!('住宿');
        await t.pumpAndSettle();
        expect(key.currentState!.costRows.single['category'], '购物');
        expect(key.currentState!.value()['costs'], isEmpty);
        await reach(t, find.text('预计预算'));
        if (!t
                .widget<ExpansionTile>(
                  find.widgetWithText(ExpansionTile, '预计预算'),
                )
                .initiallyExpanded &&
            find.text('增加费用行').evaluate().isEmpty) {
          await t.tap(find.text('预计预算'));
          await t.pumpAndSettle();
        }
        await reach(t, find.text('增加费用行'));
        await t.tap(find.text('增加费用行'));
        await t.pumpAndSettle();
        expect(key.currentState!.costRows.last['category'], '住宿');
        expect(key.currentState!.value()['costs'].single['amount'], '');
        scroll.jumpTo(0);
        await t.pumpAndSettle();
        type('游览/活动');
        await t.pumpAndSettle();
        expect(key.currentState!.costRows.last['category'], '住宿');
        expect(key.currentState!.costRows.first['category'], '购物');
        await t.pumpWidget(const SizedBox());
        s.dispose();
      },
    );
    testWidgets(
      'hotel platform draft, save, clear, cross-day cards, sync and backup $platform',
      (t) async {
        t.view.physicalSize = const Size(1440, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        final hotel = s.save('item', {
          ...itemData(trip.id, '酒店', type: '住宿'),
          'endDay': 3,
          'costs': [
            {
              'id': 'c',
              'label': '旧费用',
              'currency': 'EUR',
              'amount': '0',
              'category': '其他',
            },
          ],
        });
        final key = GlobalKey<ItemEditorState>();
        Widget page() => MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: ItemEditor(
              key: key,
              store: s,
              trip: trip,
              item: s.get(hotel.id),
              day: 1,
              onClose: () {},
            ),
          ),
        );
        await t.pumpWidget(page());
        await t.pumpAndSettle();
        await reach(t, find.widgetWithText(TextField, '预订平台（可空）'));
        await t.enterText(
          find.widgetWithText(TextField, '预订平台（可空）'),
          '酒店官网 · 任意名称',
        );
        expect(s.get(hotel.id)!.data['fields']['bookingPlatform'], isNull);
        expect(key.currentState!.value()['costs'].single['category'], '其他');
        await t.pumpWidget(const SizedBox());
        expect(s.get(hotel.id)!.data['fields']['bookingPlatform'], isNull);
        await t.pumpWidget(page());
        await t.pumpAndSettle();
        key.currentState!.field('bookingPlatform').text = 'Booking';
        expect(key.currentState!.save(close: false), true);
        expect(s.get(hotel.id)!.data['fields']['bookingPlatform'], 'Booking');
        key.currentState!.field('bookingPlatform').clear();
        expect(key.currentState!.save(close: false), true);
        expect(s.get(hotel.id)!.data['fields']['bookingPlatform'], '');
        key.currentState!.field('bookingPlatform').text = 'Agoda';
        expect(key.currentState!.save(close: false), true);
        final peer = Store(':memory:');
        peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
        expect(peer.get(hotel.id)!.data['fields']['bookingPlatform'], 'Agoda');
        final copy = Store(':memory:');
        copy.importCopy(decodeRecords(s.export()));
        expect(
          copy
              .items(copy.trips.single.id)
              .single
              .data['fields']['bookingPlatform'],
          'Agoda',
        );
        await t.pumpWidget(const SizedBox());
        s.setSetting('selectedDay', '2');
        s.setSetting('selectedTrip', trip.id);
        final sync = SyncService(s, host: true);
        await t.pumpWidget(HowDoI(store: s, sync: sync));
        await t.pumpAndSettle();
        expect(find.text('预订平台：Agoda'), findsOneWidget);
        expect(s.items(trip.id), hasLength(1));
        await t.pumpWidget(const SizedBox());
        sync.dispose();
        peer.dispose();
        copy.dispose();
        s.dispose();
      },
    );
  }
  testWidgets(
    'overview date heading hierarchy preserves calendar and undated groups',
    (t) async {
      final s = Store(':memory:');
      for (final start in ['', '2026-12-31']) {
        final trip = s.save('trip', {...tripData(), 'start': start});
        s.save('item', itemData(trip.id, '活动'));
        s.save('item', itemData(trip.id, '活动2', day: 2));
        final before = s.export();
        for (final width in [390.0, 900.0, 1440.0]) {
          t.view.physicalSize = Size(width, 960);
          t.view.devicePixelRatio = 1;
          await t.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TripOverview(
                  store: s,
                  trip: trip,
                  onDay: (_) {},
                  onItem: (_) {},
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final f = find.widgetWithText(TextButton, dayTitle(trip, 1));
          final button = t.widget<TextButton>(f);
          expect(
            button.style!.textStyle!.resolve({})!.fontWeight,
            FontWeight.w700,
          );
          expect(
            button.style!.textStyle!.resolve({})!.fontSize,
            greaterThanOrEqualTo(20),
          );
          expect(find.byType(ExpansionTile), findsNothing);
          expect(t.takeException(), isNull);
          expect(s.export(), before);
          await t.pumpWidget(const SizedBox());
        }
      }
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
      s.dispose();
    },
  );
}
