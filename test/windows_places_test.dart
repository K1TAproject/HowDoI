import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/map_links.dart';
import 'package:howdoi/maps.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;

const amap = 'https://surl.amap.com/zjlG58usfdy';
const google = 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5';
const baidu = 'https://j.map.baidu.com/3c/snKM';
Map<String, dynamic> binding(String url) => {
  'url': url,
  'provider': mapLinkProvider(url),
  'name': '酒店',
  'address': '测试地址',
  'sourceText': '酒店',
};
void main() {
  setUpAll(tz.initializeTimeZones);
  test('three official HTTPS search URLs and mixed original shares', () {
    expect(
      sharedMapLinks('墨历酒店(北京中关村理工大学店)\n酒店\n民族大学西路8号院1号楼106(1-5层)5层501\n$amap'),
      [amap],
    );
    expect(sharedMapLinks('$amap $google $baidu $amap'), [amap, google, baidu]);
    for (final invalid in [
      'https://surl.amap.com.evil.org/abc',
      'https://x@surl.amap.com/abc',
      'https://surl.amap.com:123/abc',
      'http://surl.amap.com/a',
      'file:///a',
    ]) {
      expect(mapLinkProvider(invalid), isNull);
    }
    for (final provider in ['google', 'baidu', 'amap']) {
      final uri = mapSearchUri(provider, 'Hotel & station', '北京');
      expect(uri.scheme, 'https');
      expect(
        uri.queryParameters.values,
        contains('Hotel & station${provider == 'google' ? ' 北京' : ''}'),
      );
      expect(uri.queryParameters.containsKey('ak'), false);
    }
    expect(mapSearchUri('amap', '酒店', '北京').queryParameters['callnative'], '0');
  });
  test(
    'Amap links survive bidirectional merge, repeated sync, backup and old protocol is blocked',
    () {
      final a = Store(':memory:'), b = Store(':memory:');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final trip = a.save('trip', tripData());
      final r = a.save('item', {
        ...itemData(trip.id, '酒店', type: '餐饮'),
        'locations': {'place': binding(amap)},
      });
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      expect(b.items(trip.id), hasLength(1));
      b.save('item', {
        ...b.get(r.id)!.data,
        'locations': {'place': binding(google)},
      }, id: r.id);
      a.merge(decodeRecords(b.export(sync: true), format: 'howdoi-sync'));
      expect(locationBinding(a.get(r.id)!.data, 'place')!['url'], google);
      final copy = Store(':memory:');
      addTearDown(copy.dispose);
      copy.importCopy(decodeRecords(a.export()));
      expect(
        locationBinding(
          copy.items(copy.trips.single.id).single.data,
          'place',
        )!['url'],
        google,
      );
      final old = jsonDecode(a.export(sync: true));
      old['version'] = 4;
      expect(
        () => decodeRecords(jsonEncode(old), format: 'howdoi-sync'),
        throwsFormatException,
      );
      final legacy = jsonDecode(a.export());
      legacy['version'] = 4;
      expect(decodeRecords(jsonEncode(legacy)), hasLength(a.all.length));
    },
  );
  for (final width in [420.0, 1440.0]) {
    testWidgets(
      'Windows paste confirm save original card open and failure at $width',
      (t) async {
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', tripData());
        final r = s.save('item', itemData(trip.id, '酒店', type: '餐饮'));
        s.setSetting('mapProvider:domestic', 'baidu');
        final key = GlobalKey<ItemEditorState>();
        final urls = <String>[];
        var ok = true;
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          urls.add((call.arguments as Map)['url']);
          return ok;
        });
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
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
        await t.ensureVisible(find.text('绑定地点'));
        await t.tap(find.text('绑定地点'));
        await t.pumpAndSettle();
        final input = find.widgetWithText(TextField, '地图分享文字或链接');
        await t.ensureVisible(input);
        await t.enterText(input, '酒店 $amap $google');
        await t.pump();
        expect(
          t
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '确认绑定到当前草稿'),
              )
              .onPressed,
          isNull,
        );
        await t.ensureVisible(find.text(amap));
        await t.tap(find.text(amap));
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(s.get(r.id)!.data['locations'], isNull);
        expect(
          locationBinding(key.currentState!.value(), 'place')!['url'],
          amap,
        );
        expect(key.currentState!.save(close: false), true);
        final before = s.export();
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: SingleChildScrollView(
                child: PlaceLinks(
                  store: s,
                  node: s.timeline(trip.id, 1).single,
                  onEdit: () {},
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('高德地图'), findsNothing);
        await t.tap(find.text('酒店'));
        await t.pumpAndSettle();
        expect(urls.last, amap);
        expect(s.export(), before);
        ok = false;
        await t.tap(find.text('酒店'));
        await t.pumpAndSettle();
        expect(find.text('复制链接'), findsOneWidget);
        await t.tap(find.text('重试'));
        await t.pumpAndSettle();
        expect(urls.last, amap);
        expect(s.export(), before);
        await t.tap(find.text('关闭'));
        await t.pumpAndSettle();
        await t.pumpWidget(const SizedBox());
        s.dispose();
        expect(t.takeException(), isNull);
      },
    );
  }
}
