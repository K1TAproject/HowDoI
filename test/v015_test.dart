import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/main.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/updates.dart';
import 'package:howdoi/preparations.dart';
import 'core_test.dart' show tripData, itemData;
import 'v014_test.dart' show cost;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'trip preparations keep fixed dates, reject stale writes, export/copy/delete with parent',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final old = s.save('trip', {...tripData(), 'start': ''});
      expect(s.preparations(old), isEmpty);
      s.savePreparations(old, [
        {
          'id': 'p',
          'name': '护照',
          'note': '检查',
          'due': '2026-11-12',
          'done': false,
        },
      ]);
      var trip = s.get(old.id)!;
      expect(s.visibleDays(trip.id), isEmpty);
      expect(() => s.savePreparations(old, []), throwsFormatException);
      trip = s.save('trip', {...trip.data, 'start': '2027-01-01'}, id: trip.id);
      expect(s.preparations(trip).single['due'], '2026-11-12');
      final copy = Store(':memory:');
      addTearDown(copy.dispose);
      copy.importCopy(decodeRecords(s.export(trip: trip.id)));
      final copied = copy.trips.single;
      expect(copy.preparations(copied), s.preparations(trip));
      copy.savePreparations(copied, []);
      expect(s.preparations(trip).length, 1);
      s.remove(trip);
      expect(decodeRecords(s.export()), isEmpty);
      expect(s.trips, isEmpty);
    },
  );
  test(
    'card budget handles multiple currencies, zero, unknown and whole-record wording',
    () {
      final t = Record('t', 'trip', 'd', 1, false, tripData());
      Record item(List<Map<String, dynamic>> costs) => Record(
        'i',
        'item',
        'd',
        1,
        false,
        {...itemData('t', ''), 'costs': costs},
      );
      expect(itemBudgetText(t, item([])), '');
      expect(itemBudgetText(t, item([cost('EUR', '')])), '预算未估算');
      expect(
        itemBudgetText(t, item([cost('EUR', '')]), whole: true),
        '整条行程预算未估算',
      );
      expect(
        itemBudgetText(
          t,
          item([
            cost('CNY', '200'),
            cost('EUR', '10'),
            cost('EUR', '20'),
            cost('JPY', '0'),
            cost('USD', ''),
          ]),
        ),
        '预计：CNY 200.00 · EUR 30.00 · JPY 0 · 含未估算',
      );
      expect(
        itemBudgetText(t, item([cost('EUR', '30')]), whole: true),
        '整条行程预算：EUR 30.00',
      );
    },
  );
  test('full version remains available for update checks', () async {
    expect(await appVersion(), '0.1.16+17');
  });

  for (final width in [1440.0, 700.0]) {
    testWidgets(
      'preparation create/edit/complete/order/delete and unsaved guard $width',
      (t) async {
        t.view.physicalSize = Size(width, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final sync = SyncService(s, host: true);
        final trip = s.save('trip', {...tripData(), 'start': ''});
        await t.pumpWidget(HowDoI(store: s, sync: sync));
        await t.pumpAndSettle();
        if (width < 800) {
          await t.tap(find.byIcon(Icons.menu));
          await t.pumpAndSettle();
        }
        await t.tap(find.text('预备工作'));
        await t.pumpAndSettle();
        if (width < 800) {
          expect(find.byType(Drawer), findsNothing);
        }
        for (final title in ['护照', '行李', '保险']) {
          await t.enterText(find.byType(TextField), title);
          await t.testTextInput.receiveAction(TextInputAction.done);
          await t.pumpAndSettle();
        }
        await t.enterText(find.byType(TextField), '暂未添加');
        await t.tap(find.byTooltip('关于 / 检查更新'));
        await t.pumpAndSettle();
        expect(find.text('尚未添加的准备事项'), findsOneWidget);
        await t.tap(find.text('继续编辑'));
        await t.pumpAndSettle();
        expect(
          t.widget<TextField>(find.byType(TextField)).controller!.text,
          '暂未添加',
        );
        await t.enterText(find.byType(TextField), '');
        expect(s.preparations(s.get(trip.id)!).length, 3);
        expect(s.visibleDays(trip.id), isEmpty);
        final list = t.widget<ReorderableListView>(
          find.byType(ReorderableListView).first,
        );
        list.onReorderItem!(0, 2);
        await t.pumpAndSettle();
        expect(s.preparations(s.get(trip.id)!).map((p) => p['name']), [
          '行李',
          '保险',
          '护照',
        ]);
        await t.tap(find.text('护照'));
        await t.pumpAndSettle();
        final editor = find.byType(PreparationEditor);
        final fields = find.descendant(
          of: editor,
          matching: find.byType(TextField),
        );
        await t.enterText(fields.first, '新护照');
        await t.tap(find.byTooltip('关闭准备事项'));
        await t.pumpAndSettle();
        expect(find.text('尚未保存的修改'), findsOneWidget);
        await t.tap(find.text('继续编辑'));
        await t.pumpAndSettle();
        await t.enterText(fields.last, '检查有效期');
        await t.tap(find.byTooltip('选择截止日期'));
        await t.pumpAndSettle();
        t
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .onDateChanged(DateTime(2026, 11, 12));
        await t.pumpAndSettle();
        await t.tap(find.text('保存事项'));
        await t.pumpAndSettle();
        final saved = s.preparations(s.get(trip.id)!).last;
        expect(saved['name'], '新护照');
        expect(saved['due'], '2026-11-12');
        expect(saved['note'], '检查有效期');
        await t.tap(
          find.descendant(
            of: find.widgetWithText(ListTile, '新护照'),
            matching: find.byType(Checkbox),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('已完成 1 项'), findsOneWidget);
        expect(find.text('新护照'), findsNothing);
        await t.tap(find.text('已完成 1 项'));
        await t.pumpAndSettle();
        await t.tap(find.text('新护照'));
        await t.pumpAndSettle();
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
        await t.tap(find.text('确认'));
        await t.pumpAndSettle();
        expect(s.preparations(s.get(trip.id)!).length, 2);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        sync.dispose();
        s.dispose();
      },
    );
    testWidgets(
      'drag handle centered on card with hour header and expanded notes $width',
      (t) async {
        t.view.physicalSize = Size(width, 960);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final sync = SyncService(s, host: true);
        final trip = s.save('trip', tripData());
        final item = s.save('item', {
          ...itemData(trip.id, '机场', type: '航班'),
          'endDay': 2,
          'note': '第一行\n第二行\n第三行\n第四行',
          'fields': {'startTime': '09:37', 'endTime': '08:00'},
          'costs': [cost('EUR', '30')],
        });
        await t.pumpWidget(HowDoI(store: s, sync: sync));
        await t.pumpAndSettle();
        expect(find.text('整条行程预算：EUR 30.00'), findsOneWidget);
        for (final expanded in [false, true]) {
          if (expanded) {
            await t.tap(find.textContaining('备注 ·'));
            await t.pumpAndSettle();
          }
          final card = t.getRect(find.byKey(ValueKey('card:${item.id}')));
          final handle = t.getRect(find.byKey(ValueKey('drag:${item.id}')));
          expect(handle.center.dy, closeTo(card.center.dy, .1));
          expect(card.contains(handle.center), true);
          expect(handle.size, const Size(48, 48));
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        sync.dispose();
        s.dispose();
      },
    );
  }
}
