import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/preparations.dart';
import 'package:howdoi/overview.dart';
import 'package:howdoi/day_actions.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/sync.dart';
import 'core_test.dart' show tripData, itemData;

Map<String, dynamic> cost(
  String id,
  String amount, {
  String currency = 'CNY',
  String category = '其他',
}) => {
  'id': id,
  'label': '',
  'amount': amount,
  'currency': currency,
  'category': category,
};
Map<String, dynamic> prep({List? costs}) => {
  'id': 'prep',
  'name': '签证',
  'note': '',
  'due': '',
  'done': false,
  'costs': ?costs,
};
Widget app(Widget child, TargetPlatform platform) => MaterialApp(
  theme: ThemeData(platform: platform),
  locale: const Locale('zh', 'CN'),
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  home: Scaffold(body: child),
);
Future<void> reach(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'preparation costs aggregate once, preserve currency/unknown/zero and survive sync/backup',
    () {
      final s = Store(':memory:'),
          peer = Store(':memory:'),
          copy = Store(':memory:');
      addTearDown(s.dispose);
      addTearDown(peer.dispose);
      addTearDown(copy.dispose);
      var trip = s.save('trip', {
        ...tripData(),
        'preparations': [
          prep(
            costs: [
              cost('a', '10'),
              cost('b', '0', currency: 'JPY'),
              cost('c', '', currency: 'EUR'),
            ],
          ),
        ],
      });
      final hotel = s.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿'),
        'costs': [cost('h', '20', category: '住宿')],
      });
      final b = Budget(trip, s.items(trip.id));
      expect(b.byCurrency, {'CNY': BigInt.from(3000), 'JPY': BigInt.zero});
      expect(b.unknown, 1);
      expect(itemBudgetText(trip, hotel), '预计：CNY 20.00');
      final data = TripOverviewData(s, trip);
      expect(data.costEntries.length, 4);
      expect(data.unknownCosts, 1);
      expect(data.budget.byCategory['其他']!['CNY'], BigInt.from(1000));
      s.savePreparations(trip, [
        {...prep(costs: trip.data['preparations'][0]['costs']), 'done': true},
      ]);
      trip = s.get(trip.id)!;
      expect(Budget(trip, s.items(trip.id)).byCurrency, b.byCurrency);
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      expect(peer.preparations(peer.get(trip.id)!).single['costs'].length, 3);
      copy.importCopy(decodeRecords(s.export()));
      expect(
        Budget(copy.trips.single, copy.items(copy.trips.single.id)).byCurrency,
        b.byCurrency,
      );
      for (final version in [1, 7]) {
        expect(
          decodeRecords(
            s.export().replaceFirst('"version":7', '"version":$version'),
          ),
          isNotEmpty,
        );
      }
      final old = trip;
      s.savePreparations(trip, [
        {...prep(), 'costs': []},
      ]);
      trip = s.get(trip.id)!;
      expect(Budget(trip, s.items(trip.id)).byCurrency, {
        'CNY': BigInt.from(2000),
      });
      expect(() => s.savePreparations(old, []), throwsFormatException);
      s.savePreparations(trip, []);
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      expect(peer.preparations(peer.get(trip.id)!), isEmpty);
      expect(
        () => s.save('trip', {
          ...tripData(),
          'preparations': [
            prep(costs: [cost('x', '1.5', currency: 'JPY')]),
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => s.save('trip', {
          ...tripData(),
          'preparations': [
            prep(costs: [cost('x', '1'), cost('x', '2')]),
          ],
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'clear day keeps date and related originals, tombstones synchronize; stale preview and rollback are atomic',
    () {
      final s = Store(':memory:'), peer = Store(':memory:');
      addTearDown(s.dispose);
      addTearDown(peer.dispose);
      final trip = s.save('trip', {
        ...tripData(),
        'preparations': [
          prep(costs: [cost('p', '7')]),
        ],
      });
      final stay = s.save('item', itemData(trip.id, '连住', type: '住宿'));
      final flight = s.save('item', {
        ...itemData(trip.id, '夜航', type: '航班'),
        'endDay': 2,
      });
      final normal = s.save('item', {
        ...itemData(trip.id, '当天活动', day: 2),
        'costs': [cost('n', '9')],
      });
      final other = s.save('item', itemData(trip.id, '其他日', day: 4));
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      var generation = s.generation;
      s.save('item', {...normal.data, 'note': '同步修改'}, id: normal.id);
      final before = s.export(sync: true);
      expect(
        () => s.clearDay(trip, 2, expectedGeneration: generation),
        throwsFormatException,
      );
      expect(s.export(sync: true), before);
      s.db.execute(
        "CREATE TRIGGER reject_day BEFORE INSERT ON records WHEN NEW.id LIKE 'day:%' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
      );
      expect(
        () => s.clearDay(trip, 2, expectedGeneration: s.generation),
        throwsA(anything),
      );
      expect(s.export(sync: true), before);
      s.db.execute('DROP TRIGGER reject_day');
      s.clearDay(trip, 2, expectedGeneration: s.generation);
      expect(s.get(normal.id)!.deleted, true);
      expect(s.get(stay.id)!.toJson(), stay.toJson());
      expect(s.get(flight.id)!.toJson(), flight.toJson());
      expect(s.relatedItems(trip.id, 2).length, 2);
      expect(s.visibleDays(trip.id), contains(2));
      expect(s.get(other.id)!.toJson(), other.toJson());
      expect(s.get(trip.id)!.toJson(), trip.toJson());
      expect(
        () => s.clearDay(trip, 2, expectedGeneration: s.generation),
        throwsFormatException,
      );
      s.clearDay(trip, 1, expectedGeneration: s.generation);
      expect(s.get(stay.id)!.deleted, true);
      expect(s.get(flight.id)!.deleted, true);
      expect(s.visibleDays(trip.id), [1, 2, 4]);
      expect(Budget(s.get(trip.id)!, s.items(trip.id)).byCurrency, {
        'CNY': BigInt.from(700),
      });
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      expect(peer.visibleDays(trip.id), [1, 2, 4]);
      expect(peer.items(trip.id).single.id, other.id);
    },
  );
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'preparation budget draft, empty placeholder, save and delete $platform',
      (t) async {
        t.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 900,
          900,
        );
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        addTearDown(s.dispose);
        final trip = s.save('trip', {
          ...tripData(),
          'base': 'EUR',
          'preparations': [prep()],
        });
        final key = GlobalKey<PreparationEditorState>();
        await t.pumpWidget(
          app(
            PreparationEditor(
              key: key,
              store: s,
              trip: trip,
              id: 'prep',
              onClose: () {},
            ),
            platform,
          ),
        );
        await t.pumpAndSettle();
        expect(await key.currentState!.mayLeave(), true);
        await reach(t, find.byTooltip('选择截止日期'));
        await t.tap(find.byTooltip('选择截止日期'));
        await t.pumpAndSettle();
        expect(
          t
              .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
              .initialDate,
          DateTime(2026, 10, 11),
        );
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(key.currentState!.due, '');
        await reach(t, find.text('预计预算'));
        await t.tap(find.text('预计预算'));
        await t.pumpAndSettle();
        expect(key.currentState!.costRows.single['currency'], 'EUR');
        expect(key.currentState!.costRows.single['category'], '其他');
        expect(await key.currentState!.mayLeave(), true);
        expect(key.currentState!.value().containsKey('costs'), false);
        final amount = find.widgetWithText(TextFormField, '预计金额');
        await reach(t, amount);
        await t.enterText(amount, '0');
        await t.pumpAndSettle();
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(t.view.resetViewInsets);
        await t.pumpAndSettle();
        expect(
          t.getBottomRight(find.widgetWithText(FilledButton, '保存事项')).dy,
          lessThanOrEqualTo(600),
        );
        t.view.resetViewInsets();
        await t.pumpAndSettle();
        expect(s.preparations(trip).single.containsKey('costs'), false);
        final leave = key.currentState!.mayLeave();
        await t.pumpAndSettle();
        expect(find.text('尚未保存的修改'), findsOneWidget);
        await t.tap(find.text('继续编辑'));
        await t.pumpAndSettle();
        expect(await leave, false);
        expect(key.currentState!.save(), true);
        expect(
          s.preparations(s.get(trip.id)!).single['costs'].single['amount'],
          '0',
        );
        await t.enterText(amount, '');
        await t.pumpAndSettle();
        expect(key.currentState!.save(), true);
        expect(
          s.preparations(s.get(trip.id)!).single['costs'].single['amount'],
          '',
        );
        await reach(t, find.byTooltip('移除费用'));
        await t.tap(find.byTooltip('移除费用'));
        await t.pumpAndSettle();
        expect(key.currentState!.save(), true);
        expect(s.preparations(s.get(trip.id)!).single['costs'], isEmpty);
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
        expect(find.textContaining('笔预计费用也将'), findsOneWidget);
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        expect(s.preparations(s.get(trip.id)!).length, 1);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'empty checkout follows draft checkin; existing date wins; no calendar invented $platform',
      (t) async {
        t.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 1200,
          1000,
        );
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        addTearDown(s.dispose);
        final trip = s.save('trip', {...tripData(), 'start': '2027-07-01'});
        final hotel = s.save('item', {
          ...itemData(trip.id, '酒店', type: '住宿', day: 12),
          'endDay': 0,
          'fields': {'startDate': '2027-07-12'},
        });
        final key = GlobalKey<ItemEditorState>();
        await t.pumpWidget(
          app(
            ItemEditor(
              key: key,
              store: s,
              trip: trip,
              day: 2,
              item: hotel,
              onClose: () {},
            ),
            platform,
          ),
        );
        await t.pumpAndSettle();
        Future<void> calendar(String label, DateTime expected) async {
          final f = find.byTooltip('选择$label');
          await reach(t, f);
          await t.tap(f);
          await t.pumpAndSettle();
          expect(
            t
                .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
                .initialDate,
            expected,
          );
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pumpAndSettle();
        }

        final original = jsonEncode(key.currentState!.value());
        await calendar('退房日期', DateTime(2027, 7, 12));
        expect(jsonEncode(key.currentState!.value()), original);
        key.currentState!.field('startDate').text = '2027-12-31';
        await t.pumpAndSettle();
        await calendar('退房日期', DateTime(2027, 12, 31));
        key.currentState!.field('endDate').text = '2028-01-03';
        await t.pumpAndSettle();
        await calendar('退房日期', DateTime(2028, 1, 3));
        key.currentState!.field('endDate').clear();
        key.currentState!.field('startDate').clear();
        await t.pumpAndSettle();
        await calendar('退房日期', DateTime(2027, 7, 12));
        expect(s.get(hotel.id)!.data, hotel.data);
        await t.pumpWidget(const SizedBox());
        final undated = s.save('trip', {...tripData(), 'start': ''});
        final k2 = GlobalKey<ItemEditorState>();
        await t.pumpWidget(
          app(
            ItemEditor(
              key: k2,
              store: s,
              trip: undated,
              day: 4,
              onClose: () {},
            ),
            platform,
          ),
        );
        await t.pumpAndSettle();
        await reach(t, find.byTooltip('选择安排日期'));
        await t.tap(find.byTooltip('选择安排日期'));
        await t.pumpAndSettle();
        expect(find.byType(CalendarDatePicker), findsNothing);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'clear dialog cancellation, related edit and honest result $platform',
      (t) async {
        t.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 900,
          900,
        );
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        addTearDown(s.dispose);
        final trip = s.save('trip', tripData());
        final stay = s.save('item', itemData(trip.id, '连住', type: '住宿'));
        final r = s.save('item', itemData(trip.id, '当天游览', day: 2));
        String? edited;
        await t.pumpWidget(
          app(
            Builder(
              builder: (c) => TextButton(
                onPressed: () =>
                    clearTravelDay(c, s, trip, 2, onEdit: (r) => edited = r.id),
                child: const Text('清空'),
              ),
            ),
            platform,
          ),
        );
        await t.tap(find.text('清空'));
        await t.pumpAndSettle();
        expect(find.textContaining('保留 1 条其他日期'), findsOneWidget);
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        expect(s.get(r.id)!.deleted, false);
        await t.tap(find.text('清空'));
        await t.pumpAndSettle();
        await t.tap(find.text('连住'));
        await t.pumpAndSettle();
        expect(edited, stay.id);
        expect(s.get(r.id)!.deleted, false);
        await t.tap(find.text('清空'));
        await t.pumpAndSettle();
        await t.tap(find.text('确认删除 1 条行程'));
        await t.pumpAndSettle();
        expect(s.get(r.id)!.deleted, true);
        expect(find.text('已清除当天开始的行程，仍保留 1 条关联安排'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'date menu clear respects unsaved editor and stale confirmation',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:');
      final sync = SyncService(s, host: false);
      final trip = s.save('trip', tripData());
      final r = s.save('item', itemData(trip.id, '活动'));
      await t.pumpWidget(HowDoI(store: s, sync: sync));
      await t.pumpAndSettle();
      await t.tap(find.text('活动'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '未保存活动');
      Future<void> menu() async {
        await t.tap(find.byTooltip('日期操作：第 1 天'));
        await t.pumpAndSettle();
        await t.tap(find.text('清空当天行程'));
        await t.pumpAndSettle();
      }

      await menu();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await t.tap(find.text('继续编辑'));
      await t.pumpAndSettle();
      expect(s.get(r.id)!.deleted, false);
      await menu();
      await t.tap(find.text('放弃修改'));
      await t.pumpAndSettle();
      expect(find.text('确认删除 1 条行程'), findsOneWidget);
      s.save('item', {...r.data, 'note': '预览期间另一端修改'}, id: r.id);
      await t.pumpAndSettle();
      await t.tap(find.text('确认删除 1 条行程'));
      await t.pumpAndSettle();
      expect(s.get(r.id)!.deleted, false);
      expect(find.textContaining('数据已改变'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      sync.dispose();
      s.dispose();
    },
  );
  testWidgets('overview prep budget details open preparation, not itinerary', (
    t,
  ) async {
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final trip = s.save('trip', {
      ...tripData(),
      'preparations': [
        prep(costs: [cost('c', '12')]),
      ],
    });
    String? edited;
    await t.pumpWidget(
      app(
        TripOverview(
          store: s,
          trip: trip,
          onDay: (_) {},
          onItem: (_) => fail('must not edit itinerary'),
          onPreparation: (id) => edited = id,
        ),
        TargetPlatform.windows,
      ),
    );
    await t.pumpAndSettle();
    await reach(t, find.text('CNY 12.00'));
    await t.tap(find.text('CNY 12.00'));
    await t.pumpAndSettle();
    await reach(t, find.textContaining('其他 · CNY'));
    await t.tap(find.textContaining('其他 · CNY'));
    await t.pumpAndSettle();
    await reach(t, find.text('准备事项 · 签证'));
    await t.tap(find.text('准备事项 · 签证'));
    expect(edited, 'prep');
    await t.pumpWidget(const SizedBox());
  });
}
