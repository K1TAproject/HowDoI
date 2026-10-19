import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/editors.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/maps.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;

const url = 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5';
Map<String, dynamic> link(String name, {String href = url}) => {
  'name': name,
  'address': '',
  'sourceText': name,
  'provider': 'google',
  'url': href,
};
Map<String, dynamic> point(String id, String name, {bool bound = false}) => {
  'id': id,
  'name': name,
  if (bound) 'binding': link(name),
};
Map<String, dynamic> activity(String trip, List<Map<String, dynamic>> points) =>
    {...itemData(trip, '市内观光', type: '游览/活动'), 'activityPlaces': points};
Future<void> reach(WidgetTester t, Finder finder) async {
  await t.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: find.byType(ItemEditor),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await t.pumpAndSettle();
}

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'reuse is exact, trip scoped, ambiguity safe, opt-out persistent and atomic',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', tripData()),
          otherTrip = s.save('trip', tripData());
      final a = s.save(
        'item',
        activity(trip.id, [point('a', '公园', bound: true), point('b', ' 公园 ')]),
      );
      final b = s.save('item', activity(trip.id, [point('c', '公园')]));
      final outside = s.save(
        'item',
        activity(otherTrip.id, [point('d', '公园')]),
      );
      final before = s.export();
      final p = PlaceReusePlan(s.items(trip.id), a.data, a.id);
      expect(p.count, 2);
      expect(s.export(), before);
      expect(p.others.keys, [b.id]);
      final generation = s.generation;
      s.save('item', {...b.data, 'note': 'remote'}, id: b.id);
      final changed = s.export();
      expect(
        () => s.save(
          'item',
          p.current,
          id: a.id,
          linkedChanges: p.others,
          expectedGeneration: generation,
        ),
        throwsFormatException,
      );
      expect(s.export(), changed);
      final next = PlaceReusePlan(s.items(trip.id), a.data, a.id);
      s.save(
        'item',
        next.current,
        id: a.id,
        linkedChanges: next.others,
        expectedGeneration: s.generation,
      );
      expect(locationBinding(s.get(b.id)!.data, 'activity:c')!['url'], url);
      expect(locationBinding(s.get(outside.id)!.data, 'activity:d'), isNull);
      final unbound =
          jsonDecode(jsonEncode(s.get(b.id)!.data)) as Map<String, dynamic>;
      setBinding(unbound, 'activity:c', null, blockReuse: true);
      expect(PlaceReusePlan(s.items(trip.id), unbound, b.id).count, 0);
      final ambiguous = activity(trip.id, [
        point('c', '公园'),
        {
          'id': 'x',
          'name': '公园',
          'binding': link('公园', href: 'https://maps.app.goo.gl/other'),
        },
      ]);
      expect(PlaceReusePlan(s.items(trip.id), ambiguous, b.id).count, 0);
      final stale = activity(trip.id, [
        point('c', '公园'),
        {'id': 'x', 'name': '公园', 'binding': link('旧名')},
      ]);
      expect(PlaceReusePlan(s.items(trip.id), stale, b.id).count, 0);
      final copy = Store(':memory:');
      addTearDown(copy.dispose);
      copy.importCopy(decodeRecords(s.export()));
      expect(copy.all.where((r) => r.kind == 'item').length, 3);
      final old = jsonDecode(s.export(sync: true));
      old['version'] = 5;
      expect(
        () => decodeRecords(jsonEncode(old), format: 'howdoi-sync'),
        throwsFormatException,
      );
    },
  );
  test(
    'frequency uses live records with stable fixed ties; sync and deletion agree',
    () {
      final a = Store(':memory:'), b = Store(':memory:');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final trip = a.save('trip', tripData());
      final hotel = a.save('item', itemData(trip.id, 'H', type: '住宿'));
      a.save('item', itemData(trip.id, 'F', type: '航班'));
      expect(a.frequentTypes().take(2), ['住宿', '航班']);
      a.save('item', itemData(trip.id, 'F2', type: '航班'));
      expect(a.frequentTypes().first, '航班');
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      expect(b.frequentTypes(), a.frequentTypes());
      a.remove(hotel);
      expect(a.frequentTypes().take(2), ['航班', '游览/活动']);
    },
  );
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('add reorder unlink remove and cancel preview $platform', (
      t,
    ) async {
      t.view.physicalSize = const Size(430, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final trip = store.save('trip', tripData());
      final r = store.save(
        'item',
        activity(trip.id, [point('one', '公园', bound: true)]),
      );
      final peer = store.save('item', activity(trip.id, [point('peer', '公园')]));
      final key = GlobalKey<ItemEditorState>();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: ItemEditor(
              key: key,
              store: store,
              trip: trip,
              item: r,
              day: 1,
              onClose: () {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await reach(t, find.text('添加地点'));
      await t.tap(find.text('添加地点'));
      await t.pumpAndSettle();
      await reach(t, find.widgetWithText(TextFormField, '地点 2 名称'));
      await t.enterText(find.widgetWithText(TextFormField, '地点 2 名称'), '神宫');
      await t.pump();
      await reach(t, find.byTooltip('地点上移').last);
      await t.tap(find.byTooltip('地点上移').last);
      await t.pumpAndSettle();
      expect(activityPlaces(key.currentState!.value()).map((p) => p['name']), [
        '神宫',
        '公园',
      ]);
      await reach(t, find.text('解除绑定'));
      await t.tap(find.text('解除绑定'));
      await t.pumpAndSettle();
      expect(
        locationBinding(key.currentState!.value(), 'activity:one'),
        isNull,
      );
      expect(reuseBlocked(key.currentState!.value(), 'activity:one'), true);
      expect(locationBinding(store.get(r.id)!.data, 'activity:one'), isNotNull);
      await reach(t, find.text('移除地点条目').first);
      await t.tap(find.text('移除地点条目').first);
      await t.pumpAndSettle();
      expect(activityPlaces(key.currentState!.value()).single['name'], '公园');
      // Explicitly restore only the draft, then preview must not write on cancel.
      setBinding(key.currentState!.draft, 'activity:one', link('公园'));
      final before = store.export();
      final save = key.currentState!.saveWithReuse(close: false);
      await t.pumpAndSettle();
      expect(find.textContaining('自动复用 1 个地点绑定'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(await save, false);
      expect(store.export(), before);
      final concurrent = key.currentState!.saveWithReuse(close: false);
      await t.pumpAndSettle();
      store.save('item', {...peer.data, 'note': '另一端更改'}, id: peer.id);
      final remote = store.export();
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
      expect(await concurrent, false);
      expect(store.export(), remote);
      await t.pumpWidget(const SizedBox());
      store.dispose();
      expect(t.takeException(), isNull);
    });
    testWidgets(
      'five activity points draft, original links after rename, preferences and unbound indicator $platform',
      (t) async {
        t.view.physicalSize = const Size(430, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        final names = [
          'Shiroi Koibito Park',
          '北海道神宫',
          '伏见稻荷神社',
          'Mount Moiwa Ropeway Entrance',
          '藻岩山 山顶展望台',
        ];
        final r = s.save(
          'item',
          activity(trip.id, [
            for (var i = 0; i < names.length; i++)
              point('p$i', names[i], bound: i != 0),
          ]),
        );
        final key = GlobalKey<ItemEditorState>();
        final urls = <String>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          c,
        ) async {
          urls.add((c.arguments as Map)['url']);
          return true;
        });
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: ItemEditor(
                key: key,
                store: s,
                trip: trip,
                item: r,
                day: 1,
                onClose: () {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await reach(t, find.text('绑定活动地点'));
        await t.tap(find.text('绑定活动地点'));
        await t.pumpAndSettle();
        final share = find.widgetWithText(TextField, '地图分享文字或链接');
        await t.ensureVisible(share);
        await t.enterText(share, url);
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(locationBinding(s.get(r.id)!.data, 'activity:p0'), isNull);
        key.currentState!.name.text = '札幌市内观光';
        expect(placeStale(key.currentState!.value(), 'activity:p0'), false);
        await reach(t, find.widgetWithText(TextFormField, '地点 1 名称'));
        await t.enterText(
          find.widgetWithText(TextFormField, '地点 1 名称'),
          '白色恋人公园',
        );
        await t.pump();
        expect(placeStale(key.currentState!.value(), 'activity:p0'), true);
        expect(
          locationBinding(key.currentState!.value(), 'activity:p0')!['url'],
          url,
        );
        final openLabel = platform == TargetPlatform.windows
            ? '打开地图网页'
            : '打开地图地点';
        await reach(t, find.text(openLabel).first);
        await t.tap(find.text(openLabel).first);
        await t.pumpAndSettle();
        expect(urls, [url]);
        expect(placeStale(key.currentState!.value(), 'activity:p0'), true);
        expect(locationBinding(s.get(r.id)!.data, 'activity:p0'), isNull);
        urls.clear();
        await reach(t, find.text('确认仍是此地点'));
        await t.tap(find.text('确认仍是此地点'));
        await t.pump();
        expect(placeStale(key.currentState!.value(), 'activity:p0'), false);
        expect(await key.currentState!.saveWithReuse(close: false), true);
        final saved = s.get(r.id)!;
        final before = s.export();
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    UnboundPlaces(nodes: [PlanNode(saved, 1)], onItem: (_) {}),
                    PlaceLinks(
                      store: s,
                      node: PlanNode(saved, 1),
                      onEdit: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.textContaining('个地点未绑定'), findsNothing);
        for (final name in ['白色恋人公园', ...names.skip(1)]) {
          await t.ensureVisible(find.text(name));
          await t.tap(find.text(name));
          await t.pumpAndSettle();
        }
        expect(urls, List.filled(5, url));
        expect(s.export(), before);
        await t.ensureVisible(find.byTooltip('地点操作').first);
        await t.tap(find.byTooltip('地点操作').first);
        await t.pumpAndSettle();
        await t.tap(find.text('搜索地图偏好'));
        await t.pumpAndSettle();
        expect(urls, hasLength(5));
        await t.tap(find.text('保存偏好'));
        await t.pumpAndSettle();
        expect(s.export(), before);
        await t.pumpWidget(const SizedBox());
        s.dispose();
        expect(t.takeException(), isNull);
      },
    );
    testWidgets(
      'inline costs placeholder zero unknown legacy labels and menu snapshot $platform',
      (t) async {
        t.view.physicalSize = const Size(430, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', {...tripData(), 'base': 'JPY'});
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
        await t.tap(find.byTooltip('选择活动类型'));
        await t.pumpAndSettle();
        final order = t
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .map((w) => w.value)
            .toList();
        s.save('item', itemData(trip.id, 'flight', type: '航班'));
        await t.pump();
        expect(
          t
              .widgetList<PopupMenuItem<String>>(
                find.byType(PopupMenuItem<String>),
              )
              .map((w) => w.value),
          order,
        );
        await t.tap(find.text('游览/活动').last);
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('选择活动类型'));
        await t.pumpAndSettle();
        expect(
          t
              .widgetList<PopupMenuItem<String>>(
                find.byType(PopupMenuItem<String>),
              )
              .first
              .value,
          '航班',
        );
        await t.tap(find.text('游览/活动').last);
        await t.pumpAndSettle();
        await reach(t, find.text('预计预算'));
        await t.tap(find.text('预计预算'));
        await t.pumpAndSettle();
        expect(key.currentState!.value()['costs'], isEmpty);
        await reach(t, find.widgetWithText(TextFormField, '预计金额'));
        await t.enterText(find.widgetWithText(TextFormField, '预计金额'), '0');
        await t.pump();
        expect(key.currentState!.value()['costs'].single['currency'], 'JPY');
        expect(key.currentState!.value()['costs'].single['amount'], '0');
        await t.enterText(find.widgetWithText(TextFormField, '预计金额'), '');
        await t.pump();
        expect(key.currentState!.value()['costs'].single['amount'], '');
        await reach(t, find.text('增加费用行'));
        await t.tap(find.text('增加费用行'));
        await t.pumpAndSettle();
        expect(key.currentState!.value()['costs'], hasLength(2));
        expect(find.text('费用名称'), findsNothing);
        expect(key.currentState!.save(close: false), true);
        expect(Budget(trip, s.items(trip.id)).unknown, greaterThanOrEqualTo(1));
        await t.pumpWidget(const SizedBox());
        s.dispose();
        expect(t.takeException(), isNull);
      },
    );
  }
}
