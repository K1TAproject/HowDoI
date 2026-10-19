import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/day_map.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;
import 'maps_test.dart' show place;

const url = 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5';
const pair = '40.828178925867995, 140.6934585811546';
Map<String, dynamic> bound(String name) => {
  'name': name,
  'sourceText': name,
  'address': '保留地址',
  'provider': 'google',
  'url': url,
  'position': parsePosition(pair),
};

class TestTiles extends TileProvider {
  @override
  ImageProvider getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) => MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
    ),
  );
}

class ErrorTile extends Fake implements TileImage {}

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'coordinate validation, independent sources, history isolation and protocol backup',
    () {
      expect(parsePosition(pair)!['lat'], 40.828178925867995);
      expect(parsePosition(''), isNull);
      expect(parsePosition('-90,180')!['lon'], 180);
      for (final text in [
        '1',
        '1,2,3',
        'NaN,1',
        'Infinity,2',
        '140,40',
        '40,181',
        'abc,2',
      ]) {
        expect(() => parsePosition(text), throwsFormatException, reason: text);
      }
      final original = place('旧地点');
      expect(
        currentPosition({'url': url, 'previousPosition': original}),
        isNull,
      );
      expect(currentPosition(original), isNotNull);
      final b = {
        ...bound('酒店'),
        'url': 'https://j.map.baidu.com/3c/snKM',
        'provider': 'baidu',
      };
      validateLocations({'place': b});
      expect(currentPosition(b)!['source'], 'google-manual');
      expect(
        () => validateLocations({
          'place': {
            ...b,
            'position': {...parsePosition(pair)!, 'crs': 'BD09'},
          },
        }),
        throwsFormatException,
      );
      final s = Store(':memory:'), copy = Store(':memory:');
      final trip = s.save('trip', tripData());
      s.save('item', {
        ...itemData(trip.id, '酒店', type: '餐饮'),
        'locations': {'place': b},
      });
      copy.importCopy(decodeRecords(s.export()));
      expect(
        locationBinding(copy.items(copy.trips.single.id).single.data, 'place'),
        b,
      );
      final old = jsonDecode(s.export(sync: true));
      old['version'] = 6;
      expect(
        () => decodeRecords(jsonEncode(old), format: 'howdoi-sync'),
        throwsFormatException,
      );
      old['format'] = 'howdoi-backup';
      expect(decodeRecords(jsonEncode(old)), hasLength(s.all.length));
      s.dispose();
      copy.dispose();
    },
  );
  test(
    'day points retain order, same coordinates, flight sides, stays and missing/stale positions',
    () {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final a = s.save('item', {
        ...itemData(trip.id, '观光'),
        'activityPlaces': [
          {'id': 'a', 'name': '公园', 'binding': bound('公园')},
          {'id': 'b', 'name': '车站', 'binding': bound('车站')},
          {'id': 'c', 'name': '待补充'},
        ],
      });
      final f = s.save('item', {
        ...itemData(trip.id, '航班', type: '航班'),
        'endDay': 2,
        'fields': {'origin': '出发', 'destination': '到达'},
        'locations': {'origin': bound('出发'), 'destination': bound('到达')},
      });
      final h = s.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿'),
        'locations': {'place': bound('酒店')},
      });
      final nodes = planNodes([a, f, h]);
      final first = dayVisits(nodes.where((n) => n.day == 1).toList());
      expect(dayPoints(first).map((p) => p.number), [1, 2, 4, 5]);
      final second = dayVisits(nodes.where((n) => n.day == 2).toList());
      expect(second.map((v) => v.slot), ['destination', 'place']);
      expect(dayPoints(second), hasLength(2));
      final stale = {
        ...a.data,
        'activityPlaces': [
          {'id': 'a', 'name': '更名', 'binding': bound('公园')},
        ],
      };
      expect(
        dayPoints(
          dayVisits([PlanNode(Record(a.id, 'item', 'd', 1, false, stale), 1)]),
        ),
        isEmpty,
      );
      expect(dayVisits([PlanNode(h, 3, 'end')]), isEmpty);
      s.dispose();
    },
  );
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'compact binding URL plus coordinates draft/save/change/clear/cancel $platform',
      (t) async {
        t.view.physicalSize = const Size(430, 850);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        final r = s.save('item', itemData(trip.id, '公园', type: '餐饮'));
        final before = s.export();
        final key = GlobalKey<ItemEditorState>();
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
        key.currentState!.bindExternal('place');
        await t.pumpAndSettle();
        expect(find.byType(TextField), findsNWidgets(3));
        final share = find.widgetWithText(TextField, '地图分享文字或链接'),
            coords = find.widgetWithText(TextField, '经纬度（可选，纬度，经度）');
        await t.enterText(share, url);
        await t.enterText(coords, '140,40');
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(find.textContaining('纬度必须在'), findsOneWidget);
        await t.enterText(coords, pair);
        await t.pump();
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        await t.pump();
        expect(t.getBottomLeft(find.text('确认绑定到当前草稿')).dy, lessThan(550));
        t.view.resetViewInsets();
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(s.export(), before);
        expect(
          currentPosition(
            locationBinding(key.currentState!.value(), 'place'),
          )!['lon'],
          140.6934585811546,
        );
        expect(key.currentState!.save(close: false), true);
        final saved = s.export();
        key.currentState!.bindExternal('place');
        await t.pumpAndSettle();
        await t.enterText(share, 'https://j.map.baidu.com/3c/snKM');
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(find.textContaining('请明确选择保留或清除'), findsOneWidget);
        await t.tap(find.byType(BackButton));
        await t.pumpAndSettle();
        expect(s.export(), saved);
        key.currentState!.bindExternal('place');
        await t.pumpAndSettle();
        await t.enterText(share, 'https://j.map.baidu.com/3c/snKM');
        await t.pump();
        final choice = find.byType(DropdownButtonFormField<bool>);
        await t.ensureVisible(choice);
        await t.pumpAndSettle();
        await t.tap(choice);
        await t.pumpAndSettle();
        await t.tap(find.text('保留坐标，已核对仍为同一地点').last);
        await t.pumpAndSettle();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        final retained = locationBinding(key.currentState!.value(), 'place')!;
        expect(retained['provider'], 'baidu');
        expect(currentPosition(retained)!['source'], 'google-manual');
        expect(s.export(), saved);
        key.currentState!.bindExternal('place');
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('清除坐标'));
        await t.pumpAndSettle();
        await t.tap(find.text('清除坐标'));
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(
          currentPosition(locationBinding(key.currentState!.value(), 'place')),
          isNull,
        );
        expect(
          locationBinding(key.currentState!.value(), 'place')!['url'],
          'https://j.map.baidu.com/3c/snKM',
        );
        expect(
          currentPosition(locationBinding(s.get(r.id)!.data, 'place')),
          isNotNull,
        );
        await t.pumpWidget(const SizedBox());
        s.dispose();
      },
    );
    testWidgets(
      'map markers overlap/list/open/fit/failure/retry/collapse $platform',
      (t) async {
        t.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(1100, 800)
            : const Size(430, 850);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        final r = s.save('item', {
          ...itemData(trip.id, '观光'),
          'activityPlaces': [
            {'id': '1', 'name': '车站', 'binding': bound('车站')},
            {'id': '2', 'name': '酒店', 'binding': bound('酒店')},
            {'id': '3', 'name': '待补坐标'},
          ],
        });
        final before = s.export();
        final opened = <String>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          c,
        ) async {
          opened.add((c.arguments as Map)['url']);
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
              body: SingleChildScrollView(
                child: DayMap(
                  nodes: [PlanNode(r, 1)],
                  onItem: (_) {},
                  tileProvider: TestTiles(),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('已显示 2/3 个地点'), findsOneWidget);
        expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
        expect(
          t.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
          hasLength(1),
        );
        await t.tap(find.text('1+1'));
        await t.pumpAndSettle();
        expect(find.text('此处有 2 次到访'), findsOneWidget);
        for (var i = 0; i < 2; i++) {
          await t.tap(find.text('打开原地图').at(i));
          await t.pumpAndSettle();
        }
        expect(opened, [url, url]);
        await t.tap(find.text('关闭'));
        await t.pumpAndSettle();
        await t.tap(find.text('显示全部地点'));
        await t.pumpAndSettle();
        t.widget<TileLayer>(find.byType(TileLayer)).errorTileCallback!(
          ErrorTile(),
          Exception('test failure'),
          null,
        );
        await t.pump();
        await t.pumpAndSettle();
        expect(find.text('重试地图'), findsOneWidget);
        await t.tap(find.text('重试地图'));
        await t.pumpAndSettle();
        expect(find.byType(FlutterMap), findsOneWidget);
        await t.tap(find.text('当天地图'));
        await t.pumpAndSettle();
        expect(find.byType(FlutterMap), findsNothing);
        await t.tap(find.text('当天地图'));
        await t.pumpAndSettle();
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(s.export(), before);
        await t.pumpWidget(const SizedBox());
        s.dispose();
      },
    );
  }
}
