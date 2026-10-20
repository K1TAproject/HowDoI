import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/day_map.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;
import 'coordinates016_test.dart' show bound, TestTiles;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'coordinates fill existing same URL; ambiguity, existing position and opt-out are protected',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', tripData());
      Map<String, dynamic> data(
        String id,
        Map<String, dynamic>? b, {
        bool blocked = false,
      }) => {
        ...itemData(trip.id, '活动'),
        'activityPlaces': [
          {'id': id, 'name': '车站', 'binding': ?b, 'reuseBlocked': blocked},
        ],
      };
      final full = bound('车站');
      final urlOnly = {...full}..remove('position');
      final source = s.save('item', data('a', full));
      final target = s.save('item', data('b', urlOnly));
      final blank = s.save('item', data('c', null));
      final blocked = s.save('item', data('d', null, blocked: true));
      final before = s.export();
      final plan = PlaceReusePlan(s.items(trip.id), source.data, source.id);
      expect(plan.count, 2);
      expect(plan.others.keys, containsAll([target.id, blank.id]));
      expect(plan.others.containsKey(blocked.id), false);
      expect(s.export(), before);
      expect(
        currentPosition(locationBinding(plan.others[target.id]!, 'activity:b')),
        full['position'],
      );
      s.save('item', data('e', {...full, 'position': parsePosition('41,141')}));
      expect(PlaceReusePlan(s.items(trip.id), source.data, source.id).count, 0);
    },
  );
  testWidgets(
    'expanded map fits viewport and retains duplicate visits at window scales',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '活动'),
        'activityPlaces': [
          {'id': 'a', 'name': '车站', 'binding': bound('车站')},
          {'id': 'b', 'name': '酒店', 'binding': bound('酒店')},
        ],
      });
      addTearDown(s.dispose);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      for (final scale in [1.0, 1.25, 1.5, 2.0]) {
        t.view.physicalSize = const Size(1400, 900);
        t.view.devicePixelRatio = scale;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('HowDoI')),
              body: Column(
                children: [
                  TextButton(onPressed: () {}, child: const Text('返回行程')),
                  Expanded(
                    child: DayMap(
                      nodes: [PlanNode(r, 1)],
                      onItem: (_) {},
                      fillWindow: true,
                      tileProvider: TestTiles(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.getSize(find.byType(FlutterMap)).height, greaterThan(200));
        expect(
          t.getRect(find.byType(FlutterMap)).bottom,
          lessThanOrEqualTo(900 / scale),
        );
        await t.tap(find.text('1+1'));
        await t.pumpAndSettle();
        expect(find.text('此处有 2 次到访'), findsOneWidget);
        await t.tap(find.text('关闭'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'window expansion preserves actual home scroll, draft and unsaved protection',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:');
      final sync = SyncService(s, host: true);
      final trip = s.save('trip', tripData());
      for (var i = 0; i < 20; i++) {
        s.save('item', itemData(trip.id, '地点 $i'));
      }
      await t.pumpWidget(HowDoI(store: s, sync: sync));
      await t.pumpAndSettle();
      await t.tap(find.text('添加行程'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '未保存草稿');
      final state = t.state<ItemEditorState>(find.byType(ItemEditor));
      final scroll = t
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ReorderableListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final expand = t.widget<DayMap>(find.byType(DayMap)).onExpand!;
      scroll.jumpTo(100);
      await t.pumpAndSettle();
      final offset = scroll.pixels;
      final before = s.export();
      expand();
      await t.pumpAndSettle();
      expect(find.byType(ItemEditor), findsNothing);
      expect(find.text('返回行程'), findsOneWidget);
      t.view.physicalSize = const Size(1000, 700);
      await t.pumpAndSettle();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      t.view.physicalSize = const Size(1440, 960);
      await t.pumpAndSettle();
      await t.tap(find.text('返回行程'));
      await t.pumpAndSettle();
      expect(
        identical(t.state<ItemEditorState>(find.byType(ItemEditor)), state),
        true,
      );
      expect(scroll.pixels, offset);
      expect(
        t.widget<TextField>(find.byType(TextField).first).controller!.text,
        '未保存草稿',
      );
      expect(s.export(), before);
      await t.tap(find.text('添加日期').first);
      await t.pumpAndSettle();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await t.tap(find.text('继续编辑'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      sync.dispose();
      s.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
