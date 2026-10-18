import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/editors.dart';
import 'package:howdoi/maps.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;
import 'maps_test.dart' show place;

void main() {
  setUpAll(() {
    tz.initializeTimeZones();
    BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: Directory('work/maps-widget-cache').absolute.path,
    );
  });
  testWidgets(
    'Windows retains both-end binding; explicit candidate/manual draft, save, sync and direct navigation',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:'), desktop = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '', type: '交通/移动'),
        'fields': {'origin': '机场', 'destination': '东京站'},
      });
      s.setSetting(
        'mapSearch:${sha256.convert(utf8.encode('$searchEndpoint\n机场'))}',
        jsonEncode([
          {...place('同名机场'), 'id': 'node/1'},
          {...place('同名机场'), 'id': 'node/2', 'lat': 36.0},
        ]),
      );
      final key = GlobalKey<ItemEditorState>();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
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
      await t.ensureVisible(find.text('设置起点'));
      await t.tap(find.text('设置起点'));
      await t.pumpAndSettle();
      expect(find.text('选择地点'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认地点'))
            .onPressed,
        isNull,
      );
      await t.tap(find.text('搜索'));
      await t.pumpAndSettle();
      expect(find.text('同名机场'), findsNWidgets(2));
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认地点'))
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.text('同名机场').last);
      await t.tap(find.text('同名机场').last);
      await t.pumpAndSettle();
      expect(
        t.widget<PlaceMap>(find.byType(PlaceMap)).points.single['id'],
        'node/2',
      );
      await t.tap(find.text('确认地点'));
      await t.pumpAndSettle();
      expect(s.get(r.id)!.data['locations'], isNull);
      expect(linkedPlace(key.currentState!.value(), 'origin')!['lat'], 36.0);
      await t.ensureVisible(find.text('设置终点'));
      await t.tap(find.text('设置终点'));
      await t.pumpAndSettle();
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      expect(t.getBottomLeft(find.text('确认地点')).dy, lessThan(544));
      t.view.resetViewInsets();
      await t.pump();
      final map = t.widget<PlaceMap>(find.byType(PlaceMap));
      map.onPick!(const LatLng(35.6812, 139.7671));
      await t.pumpAndSettle();
      await t.tap(find.text('确认地点'));
      await t.pumpAndSettle();
      expect(
        linkedPlace(key.currentState!.value(), 'destination')!['provider'],
        'manual',
      );
      expect(s.get(r.id)!.data['locations'], isNull);
      final leaving = key.currentState!.mayLeave();
      await t.pumpAndSettle();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await t.tap(find.text('继续编辑'));
      await t.pumpAndSettle();
      expect(await leaving, false);
      expect(key.currentState!.save(close: false), true);
      desktop.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      expect(
        mapVisits(
          desktop.timeline(trip.id, 1),
          daily: true,
        ).where((v) => v.place != null),
        hasLength(2),
      );
      final backup = decodeRecords(s.export());
      expect(
        backup.where((v) => v.id == r.id).single.data['locations'],
        s.get(r.id)!.data['locations'],
      );
      final urls = <Uri>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        urls.add(Uri.parse((call.arguments as Map)['url']));
        return true;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      s.setSetting('mapRegion', 'overseas');
      s.setSetting('mapProvider:overseas', 'google');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavigationActions(store: s, data: s.get(r.id)!.data),
          ),
        ),
      );
      await t.tap(find.text('导航'));
      await t.pumpAndSettle();
      expect(urls.single.queryParameters['destination'], '35.6812,139.7671');
      expect(urls.single.queryParameters.containsKey('origin'), false);
      expect(find.byType(AlertDialog), findsNothing);
      await t.pumpWidget(const SizedBox());
      s.dispose();
      desktop.dispose();
    },
  );
  testWidgets(
    'existing location survives cancel and failed search; replacement and unlink stay in draft',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿'),
        'locations': {'place': place('酒店')},
      });
      final key = GlobalKey<ItemEditorState>();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
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
      await t.scrollUntilVisible(
        find.text('更换 / 核对'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.widgetWithText(FilledButton, '更换 / 核对'));
      await t.pumpAndSettle();
      await t.tap(find.text('更换 / 核对'));
      await t.pumpAndSettle();
      expect(
        t.widget<PlaceMap>(find.byType(PlaceMap)).points.single['name'],
        '酒店',
      );
      s.setSetting('mapSearchEndpoint', 'http://invalid');
      await t.tap(find.text('搜索'));
      await t.pumpAndSettle();
      expect(find.textContaining('必须使用'), findsOneWidget);
      expect(
        t.widget<PlaceMap>(find.byType(PlaceMap)).points.single['name'],
        '酒店',
      );
      t.widget<PlaceMap>(find.byType(PlaceMap)).onPick!(
        const LatLng(48.8, 2.3),
      );
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(linkedPlace(key.currentState!.value(), 'place')!['lat'], 35.6812);
      await t.ensureVisible(find.text('解除关联'));
      await t.tap(find.text('解除关联'));
      await t.pumpAndSettle();
      expect(linkedPlace(key.currentState!.value(), 'place'), isNull);
      expect(linkedPlace(s.get(r.id)!.data, 'place'), isNotNull);
      await t.pumpWidget(const SizedBox());
      s.dispose();
    },
  );
}
