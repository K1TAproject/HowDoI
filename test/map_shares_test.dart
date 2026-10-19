import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/map_links.dart';
import 'package:howdoi/share_inbox.dart';
import 'package:howdoi/external_binding.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/maps.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/home.dart';
import 'package:howdoi/sync.dart';
import 'core_test.dart' show tripData, itemData;
import 'maps_test.dart' show place;

const google = 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5';
const baidu = 'https://j.map.baidu.com/3c/snKM';
void main() {
  setUpAll(tz.initializeTimeZones);
  test('recognized original URLs only; no viewport coordinate inference', () {
    expect(sharedMapLinks('酒店说明 $google。\n$baidu'), [google, baidu]);
    for (final bad in [
      'https://maps.app.goo.gl.evil.test/a',
      'http://j.map.baidu.com/3c/snKM',
      'https://user@maps.app.goo.gl/a',
      'https://maps.app.goo.gl:444/a',
      'javascript:alert(1)',
      'https://google.com/search?q=hotel',
    ]) {
      expect(mapLinkProvider(bad), isNull);
    }
    expect(
      mapLinkProvider('https://www.google.com/maps/@35,139,15z'),
      'google',
    );
  });
  test(
    'links and inactive historical positions preserve sync and backup; old protocol rejected',
    () {
      final a = Store(':memory:'), b = Store(':memory:');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final trip = a.save('trip', tripData());
      final binding = {
        'name': '酒店',
        'address': '',
        'sourceText': '酒店',
        'url': google,
        'provider': 'google',
        'previousPosition': place('酒店'),
      };
      final r = a.save('item', {
        ...itemData(trip.id, '酒店', type: '餐饮'),
        'locations': {'place': binding},
      });
      expect(linkedPlace(r.data, 'place'), isNull);
      expect(hasPlace(r.data, 'place'), isTrue);
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      expect(b.get(r.id)!.data['locations'], r.data['locations']);
      b.importCopy(decodeRecords(a.export()));
      expect(
        b.items(b.trips.last.id).single.data['locations'],
        r.data['locations'],
      );
      final old = jsonDecode(a.export(sync: true));
      old['version'] = 3;
      expect(
        () => decodeRecords(jsonEncode(old), format: 'howdoi-sync'),
        throwsFormatException,
      );
      expect(
        mapVisits(a.timeline(trip.id, 1)).where((v) => v.place != null),
        isEmpty,
      );
    },
  );
  testWidgets(
    'Android sharing confirms draft, preserves old coordinates, saves and opens exact link',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '酒店', type: '餐饮'),
        'locations': {'place': place('酒店')},
      });
      final key = GlobalKey<ItemEditorState>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Map<String, String>? inbox;
      messenger.setMockMethodCallHandler(MapShareInbox.channel, (c) async {
        if (c.method == 'peek') return inbox;
        if (c.method == 'ack') {
          inbox = null;
        }
        return null;
      });
      final opened = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (c) async {
          opened.add((c.arguments as Map)['url']);
          return true;
        },
      );
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
      await t.ensureVisible(find.text('更换绑定'));
      await t.tap(find.text('更换绑定'));
      await t.pumpAndSettle();
      expect(find.byType(ExternalBindingPage), findsOneWidget);
      expect(find.text('选择地点'), findsNothing);
      expect(find.text('搜索服务设置'), findsNothing);
      inbox = {'id': 'one', 'text': '我选的酒店 $google 和 $baidu'};
      await MapShareInbox.instance.refresh();
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '确认绑定到当前草稿'),
            )
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.text(google));
      await t.tap(find.text(google));
      await t.pump();
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      expect(t.getBottomLeft(find.text('确认绑定到当前草稿')).dy, lessThan(544));
      t.view.resetViewInsets();
      await t.pump();
      await t.tap(find.text('确认绑定到当前草稿'));
      await t.pumpAndSettle();
      expect(
        locationBinding(key.currentState!.value(), 'place')!['url'],
        google,
      );
      expect(
        locationBinding(
          key.currentState!.value(),
          'place',
        )!['previousPosition'],
        place('酒店'),
      );
      expect(linkedPlace(s.get(r.id)!.data, 'place'), isNotNull);
      final leaving = key.currentState!.mayLeave();
      await t.pumpAndSettle();
      await t.tap(find.text('继续编辑'));
      await t.pumpAndSettle();
      expect(await leaving, false);
      expect(key.currentState!.save(close: false), true);
      await t.ensureVisible(find.text('打开地图地点'));
      await t.tap(find.text('打开地图地点'));
      await t.pumpAndSettle();
      expect(opened.last, google);
      await t.ensureVisible(find.text('解除绑定'));
      await t.tap(find.text('解除绑定'));
      await t.pump();
      expect(locationBinding(key.currentState!.value(), 'place'), isNull);
      expect(locationBinding(s.get(r.id)!.data, 'place')!['url'], google);
      await t.pumpWidget(const SizedBox());
      s.dispose();
      MapShareInbox.instance.value = null;
      messenger.setMockMethodCallHandler(MapShareInbox.channel, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      );
    },
  );
  testWidgets(
    'pending saved target is reconfirmed after cold recovery; cancellation does not overwrite',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '车次', type: '交通/移动'),
        'fields': {'origin': '机场', 'destination': '酒店'},
      });
      s.setSetting(
        'pendingMapBinding',
        jsonEncode({'trip': trip.id, 'item': r.id, 'slot': 'destination'}),
      );
      final sync = SyncService(s, host: false);
      MapShareInbox.instance.value = {'id': 'cold', 'text': baidu};
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Home(store: s, sync: sync),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.mark_email_unread));
      await t.pumpAndSettle();
      expect(find.text('选择地图链接绑定目标'), findsOneWidget);
      expect(find.textContaining('未保存草稿无法恢复'), findsOneWidget);
      expect(s.get(r.id)!.data['locations'], isNull);
      await t.tap(find.text('确认目标'));
      await t.pumpAndSettle();
      expect(find.text('绑定终点'), findsOneWidget);
      expect(find.textContaining('确认目标：'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      expect(s.get(r.id)!.data['locations'], isNull);
      expect(MapShareInbox.instance.value!['id'], 'cold');
      await t.pumpWidget(const SizedBox());
      MapShareInbox.instance.value = null;
      sync.dispose();
      s.dispose();
    },
  );
  testWidgets(
    'transport origin and destination pasted links remain separate drafts; invalid paste cannot confirm',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '', type: '交通/移动'),
        'fields': {'origin': '机场', 'destination': '酒店'},
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
      for (final slot in ['origin', 'destination']) {
        final button = slot == 'origin' ? '绑定起点' : '绑定终点';
        await Scrollable.ensureVisible(
          t.element(find.text(button)),
          alignment: 0.4,
        );
        await t.pumpAndSettle();
        await t.tap(find.text(button));
        await t.pumpAndSettle();
        final input = find.widgetWithText(TextField, '地图分享文字或链接');
        await t.ensureVisible(input);
        await t.enterText(input, 'https://evil.test/point');
        await t.pump();
        expect(
          t
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '确认绑定到当前草稿'),
              )
              .onPressed,
          isNull,
        );
        await t.enterText(input, slot == 'origin' ? baidu : google);
        await t.pump();
        await t.tap(find.text('确认绑定到当前草稿'));
        await t.pumpAndSettle();
        expect(s.get(r.id)!.data['locations'], isNull);
      }
      expect(
        locationBinding(key.currentState!.value(), 'origin')!['url'],
        baidu,
      );
      expect(
        locationBinding(key.currentState!.value(), 'destination')!['url'],
        google,
      );
      expect(key.currentState!.save(close: false), true);
      final before = s.export();
      final urls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (c) async {
              urls.add((c.arguments as Map)['url']);
              return false;
            },
          );
      final context = t.element(find.byType(ItemEditor));
      final opening = navigatePlace(
        context,
        s,
        s.get(r.id)!.data,
        slot: 'destination',
      );
      await t.pumpAndSettle();
      expect(urls, [google]);
      expect(find.text('复制链接'), findsOneWidget);
      await t.tap(find.text('关闭'));
      await t.pumpAndSettle();
      await opening;
      expect(s.export(), before);
      await t.pumpWidget(const SizedBox());
      s.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          );
    },
  );
}
