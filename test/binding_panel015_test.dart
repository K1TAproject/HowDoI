import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/editors.dart';
import 'package:howdoi/external_binding.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/map_links.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;

const link = 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5';
void main() {
  setUpAll(tz.initializeTimeZones);
  testWidgets(
    'wide binding stays inside editor; confirm cancel and leave retain draft and scroll',
    (t) async {
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', itemData(trip.id, '餐厅', type: '餐饮'));
      final before = s.export();
      final key = GlobalKey<ItemEditorState>();
      final central = ScrollController();
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 220, child: Text('旅行导航')),
                Expanded(
                  child: ListView(
                    controller: central,
                    children: List.generate(
                      60,
                      (i) => SizedBox(height: 60, child: Text('当天行程 $i')),
                    ),
                  ),
                ),
                SizedBox(
                  width: 410,
                  child: ItemEditor(
                    key: key,
                    embeddedBinding: true,
                    store: s,
                    trip: trip,
                    item: r,
                    day: 1,
                    onClose: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      central.jumpTo(600);
      await t.ensureVisible(find.text('绑定地点'));
      final editorScroll = t
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ItemEditor),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final offset = editorScroll.pixels;
      await t.tap(find.text('绑定地点'));
      await t.pumpAndSettle();
      expect(t.getRect(find.byType(ExternalBindingPage)).left, 1030);
      expect(t.getRect(find.byType(ExternalBindingPage)).width, 410);
      expect(find.text('旅行导航').hitTestable(), findsOneWidget);
      expect(central.offset, 600);
      final shared = find.widgetWithText(TextField, '地图分享文字或链接');
      await t.ensureVisible(shared);
      await t.enterText(shared, link);
      await t.pump();
      await t.tap(find.text('确认绑定到当前草稿'));
      await t.pumpAndSettle();
      expect(find.byType(ExternalBindingPage), findsNothing);
      expect(locationBinding(key.currentState!.value(), 'place')!['url'], link);
      expect(s.export(), before);
      expect(editorScroll.pixels, offset);
      expect(central.offset, 600);
      await key.currentState!.bindExternal('place');
      await t.pumpAndSettle();
      await t.ensureVisible(shared);
      await t.enterText(shared, 'https://j.map.baidu.com/3c/snKM');
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(locationBinding(key.currentState!.value(), 'place')!['url'], link);
      expect(s.export(), before);
      await key.currentState!.bindExternal('place');
      await t.pumpAndSettle();
      expect(await key.currentState!.mayLeave(), false);
      await t.pumpAndSettle();
      expect(find.byType(ExternalBindingPage), findsNothing);
      final leaving = key.currentState!.mayLeave();
      await t.pumpAndSettle();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await t.tap(find.text('继续编辑'));
      await t.pumpAndSettle();
      expect(await leaving, false);
      expect(await key.currentState!.saveWithReuse(close: false), true);
      expect(locationBinding(s.get(r.id)!.data, 'place')!['url'], link);
      await t.pumpWidget(const SizedBox());
      central.dispose();
      s.dispose();
    },
  );
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('narrow $platform retains page binding and cancellation', (
      t,
    ) async {
      t.view.physicalSize = const Size(430, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', itemData(trip.id, '餐厅', type: '餐饮'));
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
      expect(t.getRect(find.byType(ExternalBindingPage)).width, 430);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(locationBinding(key.currentState!.value(), 'place'), isNull);
      expect(await key.currentState!.mayLeave(), true);
      await t.pumpWidget(const SizedBox());
      s.dispose();
    });
  }
  testWidgets(
    'Windows explicit copy does not launch; repeated searches and provider changes use HTTPS',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      s.setSetting('mapRegion', 'overseas');
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (c) async {
          if (c.method == 'Clipboard.setData') {
            copied = (c.arguments as Map)['text'];
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final before = s.export();
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
          theme: ThemeData(platform: TargetPlatform.windows),
          home: ExternalBindingPage(
            store: s,
            tripId: trip.id,
            target: '测试',
            slot: 'place',
            sourceText: '酒店',
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('去地图搜索'));
      await t.pumpAndSettle();
      for (final provider in ['google', 'baidu', 'amap']) {
        s.setSetting('mapProvider:overseas', provider);
        await t.ensureVisible(find.text('复制搜索网址'));
        await t.pumpAndSettle();
        await t.tap(find.text('复制搜索网址'));
        await t.pumpAndSettle();
        expect(copied, mapSearchUri(provider, '酒店', '').toString());
        expect(urls.length, ['google', 'baidu', 'amap'].indexOf(provider));
        await t.tap(find.text('打开地图网页搜索'));
        await t.pumpAndSettle();
        expect(urls.last, mapSearchUri(provider, '酒店', '').toString());
        expect(s.export(), before);
      }
      expect(find.textContaining('不支持指定或跟踪标签页'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      s.dispose();
    },
  );
}
