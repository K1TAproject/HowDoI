import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/main.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/editors.dart';
import 'core_test.dart' show tripData, itemData;

Map<String, dynamic> cost(
  String currency,
  String amount, {
  String category = '交通',
}) => {
  'id': '$currency-$amount-$category',
  'label': '',
  'currency': currency,
  'amount': amount,
  'category': category,
};

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'original currency/category sums ignore FX, preserve zero/unknown and old backup data',
    () {
      final store = Store(':memory:');
      addTearDown(store.dispose);
      final trip = store.save('trip', tripData());
      final item = store.save('item', {
        ...itemData(trip.id, '预算'),
        'costs': [
          cost('CNY', '2000'),
          cost('EUR', '100.01'),
          cost('EUR', '249.99'),
          cost('JPY', '12000'),
          cost('USD', '0', category: '餐饮'),
          cost('GBP', ''),
        ],
      });
      final b = Budget(trip, store.items(trip.id));
      expect(b.byCurrency, {
        'CNY': BigInt.from(200000),
        'EUR': BigInt.from(35000),
        'JPY': BigInt.from(12000),
        'USD': BigInt.zero,
      });
      expect(b.byCategory['交通']!['EUR'], BigInt.from(35000));
      expect(b.byCategory['餐饮'], {'USD': BigInt.zero});
      expect(b.unknown, 1);
      expect(formatUnits(b.byCurrency['JPY']!, digits('JPY')), '12000');
      final modified = store.save('trip', {
        ...trip.data,
        'base': 'JPY',
      }, id: trip.id);
      expect(Budget(modified, store.items(trip.id)).byCurrency, b.byCurrency);
      expect(store.get(item.id)!.toJson(), item.toJson());
      for (final version in [1, 2, 3]) {
        final copy = Store(':memory:');
        copy.importCopy(
          decodeRecords(
            store.export().replaceFirst('"version":7', '"version":$version'),
          ),
        );
        expect(
          copy
              .items(copy.trips.single.id)
              .single
              .data['costs']
              .map((c) => [c['amount'], c['currency'], c['category']]),
          item.data['costs'].map(
            (c) => [c['amount'], c['currency'], c['category']],
          ),
        );
        expect(copy.trips.single.data['rates'], trip.data['rates']);
        expect(
          Budget(
            copy.trips.single,
            copy.items(copy.trips.single.id),
          ).byCurrency,
          b.byCurrency,
        );
        copy.dispose();
      }
    },
  );

  for (final width in [1440.0, 700.0]) {
    testWidgets(
      'sidebar/drawer spacing and deletion snackbar expiry/replacement $width',
      (t) async {
        t.view.physicalSize = Size(width, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final store = Store(':memory:');
        final sync = SyncService(store, host: true);
        final trip = store.save('trip', {...tripData(), 'start': ''});
        store.addDay(trip);
        store.addDay(trip);
        store.addDay(trip);
        await t.pumpWidget(HowDoI(store: store, sync: sync));
        await t.pumpAndSettle();
        if (width < 800) {
          await t.tap(find.byIcon(Icons.menu));
          await t.pumpAndSettle();
        }
        final create = find.widgetWithText(OutlinedButton, '创建旅行');
        final add = find.widgetWithText(OutlinedButton, '添加日期');
        expect(t.getRect(add).top - t.getRect(create).bottom, closeTo(12, 0.1));
        expect(t.getSize(create), t.getSize(add));
        Future<void> remove(int day) async {
          await t.tap(find.byTooltip('日期操作：第 $day 天'));
          await t.pumpAndSettle();
          await t.tap(find.text('删除日期'));
          await t.pumpAndSettle();
        }

        await remove(3);
        await t.pump(const Duration(seconds: 3));
        await remove(2);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('已删除 第 2 天'), findsOneWidget);
        expect(find.text('已删除 第 3 天'), findsNothing);
        // Close drawer before clicking the snackbar on the scaffold behind it.
        if (width < 800) {
          Navigator.of(t.element(find.byType(Drawer))).pop();
          await t.pumpAndSettle();
        }
        await t.tap(find.text('撤销'));
        await t.pumpAndSettle();
        expect(store.visibleDays(trip.id), [1, 2]);
        expect(find.byType(SnackBar), findsNothing);
        if (width < 800) {
          await t.tap(find.byIcon(Icons.menu));
          await t.pumpAndSettle();
        }
        await remove(2);
        final generation = store.generation;
        await t.pump(const Duration(seconds: 6));
        expect(find.byType(SnackBar), findsOneWidget);
        await t.pump(const Duration(seconds: 2));
        await t.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(store.generation, generation);
        expect(store.visibleDays(trip.id), [1]);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        sync.dispose();
        store.dispose();
      },
    );
  }

  testWidgets(
    'default currency edit preserves legacy FX and existing costs; new cost preselects default',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', tripData());
      final item = store.save('item', {
        ...itemData(trip.id, '旧费用'),
        'costs': [cost('EUR', '100')],
      });
      await t.pumpWidget(HowDoI(store: store, sync: sync));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('旅行操作：北欧旅行'));
      await t.pumpAndSettle();
      await t.tap(find.text('编辑旅行'));
      await t.pumpAndSettle();
      expect(find.text('手动汇率'), findsNothing);
      expect(find.text('默认预算币种'), findsOneWidget);
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('JPY').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.get(trip.id)!.data['base'], 'JPY');
      expect(store.get(trip.id)!.data['rates'], trip.data['rates']);
      expect(store.get(item.id)!.toJson(), item.toJson());
      await t.tap(find.byTooltip('预算'));
      await t.pumpAndSettle();
      expect(find.text('预计预算'), findsOneWidget);
      expect(find.text('100.00'), findsNWidgets(2));
      expect(find.textContaining('折算'), findsNothing);
      expect(find.text('JPY'), findsNothing);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      await t.tap(find.text('旧费用'));
      await t.pumpAndSettle();
      final editor = t.state<ItemEditorState>(find.byType(ItemEditor));
      expect(editor.blankCost()['currency'], 'JPY');
      expect(editor.value()['costs'][0]['currency'], 'EUR');
      await t.scrollUntilVisible(
        find.text('预计预算'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(ItemEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.tap(find.text('预计预算'));
      await t.pumpAndSettle();
      expect(find.text('费用名称'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
}
