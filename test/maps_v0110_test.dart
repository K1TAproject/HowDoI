import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/maps.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/home.dart';
import 'package:howdoi/sync.dart';
import 'package:howdoi/overview.dart';
import 'package:howdoi/editors.dart';
import 'core_test.dart' show tripData, itemData;
import 'maps_test.dart' show place;

void main() {
  setUpAll(() {
    tz.initializeTimeZones();
    BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: Directory('work/maps-widget-cache').absolute.path,
    );
  });
  test('navigation targets follow cross-day and lodging references', () {
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final trip = s.save('trip', tripData());
    final flight = s.save('item', {
      ...itemData(trip.id, '', type: '航班'),
      'endDay': 2,
      'fields': {'origin': '北京', 'destination': '东京'},
    });
    final nodes = planNodes([flight]);
    expect(navigationSlot(nodes.first), 'origin');
    expect(navigationSlot(nodes.last), 'destination');
    expect(mapVisits([nodes.first], daily: true).map((v) => v.slot), [
      'origin',
    ]);
    expect(mapVisits([nodes.last], daily: true).map((v) => v.slot), [
      'destination',
    ]);
    final hotel = s.save('item', {
      ...itemData(trip.id, '酒店', type: '住宿'),
      'fields': {'endTime': '11:00'},
    });
    expect(
      mapVisits(planNodes([hotel]).where((n) => n.day == 3), daily: true),
      isEmpty,
    );
    expect(
      mapVisits(planNodes([hotel]).where((n) => n.day == 2), daily: true),
      hasLength(1),
    );
  });
  testWidgets(
    'daily map has no lines, overlapping visits stay accessible; empty is compact',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final a = s.save('item', {
        ...itemData(trip.id, '第一站'),
        'locations': {'place': place('第一站')},
      });
      final b = s.save('item', {
        ...itemData(trip.id, '第二站'),
        'locations': {'place': place('第二站')},
      });
      String? opened;
      for (final width in [1100.0, 390.0]) {
        t.view.physicalSize = Size(width, 844);
        t.view.devicePixelRatio = 1;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  TripMap(
                    nodes: planNodes([a, b]),
                    daily: true,
                    onItem: (r) => opened = r.id,
                  ),
                ],
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 200));
        final map = t.widget<PlaceMap>(find.byType(PlaceMap));
        expect(map.connections, isEmpty);
        expect(map.points, hasLength(2));
        map.onPoint!(1);
        await t.pumpAndSettle();
        expect(find.text('1. 第一站'), findsOneWidget);
        expect(find.text('2. 第二站'), findsOneWidget);
        await t.tap(find.text('1. 第一站'));
        await t.pumpAndSettle();
        expect(opened, a.id);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      }
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TripMap(nodes: [], daily: true, onItem: (_) {}),
          ),
        ),
      );
      expect(find.byType(PlaceMap), findsNothing);
      expect(find.textContaining('尚无已确认位置'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      s.dispose();
    },
  );
  testWidgets(
    'platform entrypoints: Windows inline day map; Android cards and overview no maps',
    (t) async {
      final s = Store(':memory:');
      final sync = SyncService(s, host: false);
      final trip = s.save('trip', tripData());
      s.save('item', itemData(trip.id, '东京站'));
      for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Home(store: s, sync: sync),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('查看当天地图'), findsNothing);
        expect(
          find.text('当天地点'),
          platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationActions),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        await t.pumpWidget(const SizedBox());
      }
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
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
      expect(find.text('查看旅行地图'), findsNothing);
      expect(find.byType(PlaceMap), findsNothing);
      expect(find.byType(NavigationActions), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      sync.dispose();
      s.dispose();
    },
  );
  testWidgets(
    'direct launch, remembered provider, stale search and failed-launch fallback preserve data',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '东京'),
        'locations': {'place': place('东京')},
      });
      final urls = <Uri>[];
      var success = true;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        urls.add(Uri.parse((call.arguments as Map)['url']));
        return success;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final draft = {...r.data};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => navigatePlace(c, s, draft),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(urls.single.host, 'www.google.com');
      expect(find.byType(AlertDialog), findsNothing);
      expect(s.setting('mapProvider:overseas'), 'google');
      s.setSetting('mapProvider:overseas', 'baidu');
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(urls.last.scheme, 'baidumap');
      expect(urls.last.queryParameters['coord_type'], 'wgs84');
      draft['name'] = '京都';
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(urls.last.path, '/geocoder');
      expect(urls.last.queryParameters['address'], '京都');
      expect(s.get(r.id)!.data['name'], '东京');
      success = false;
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.textContaining('无法打开地图'), findsOneWidget);
      expect(find.text('网页搜索 / 打开'), findsOneWidget);
      expect(find.text('复制地址'), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      s.dispose();
    },
  );
  testWidgets('Android editor keeps draft and unlink without inline map', (
    t,
  ) async {
    final s = Store(':memory:');
    final trip = s.save('trip', tripData());
    final r = s.save('item', {
      ...itemData(trip.id, '东京'),
      'locations': {'place': place('东京')},
    });
    final key = GlobalKey<ItemEditorState>();
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
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
    await t.ensureVisible(find.text('地图地点（可选）'));
    await t.pumpAndSettle();
    expect(find.text('更换 / 核对'), findsOneWidget);
    expect(find.byType(PlaceMap), findsNothing);
    await t.ensureVisible(find.text('解除关联'));
    await t.tap(find.text('解除关联'));
    await t.pumpAndSettle();
    expect(key.currentState!.value()['locations'], isEmpty);
    expect(s.get(r.id)!.data['locations'], isNotEmpty);
    await t.pumpWidget(const SizedBox());
    s.dispose();
  });
}
