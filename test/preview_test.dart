import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      Future.value(
        ByteData.sublistView(
          File(
            '.tools/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
          ).readAsBytesSync(),
        ),
      ),
    );
    await icons.load();
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('Microsoft YaHei');
      loader.addFont(
        Future.value(ByteData.sublistView(font.readAsBytesSync())),
      );
      await loader.load();
    }
  });
  for (final width in [1440, 900, 390]) {
    testWidgets('Preview and detailed editor $width', (tester) async {
      tester.view.physicalSize = Size(width.toDouble(), 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', tripData());
      store.savePreparations(trip, [
        {
          'id': 'p1',
          'name': '检查护照有效期',
          'due': '2026-10-01',
          'note': '确认入境要求',
          'done': false,
        },
        {'id': 'p2', 'name': '购买旅行保险', 'due': '', 'note': '', 'done': false},
        {'id': 'p3', 'name': '预订机票', 'due': '', 'note': '', 'done': true},
      ]);
      final flight = itemData(trip.id, '飞往赫尔辛基', type: '航班');
      flight['fields'] = {
        'startTime': '02:00',
        'endTime': '06:00',
        'startZone': 'Asia/Shanghai',
        'endZone': 'Europe/Helsinki',
        'number': 'AY 示例',
        'origin': '北京',
        'destination': '赫尔辛基',
      };
      flight['booking'] = '已预订';
      final plane = store.save('item', flight);
      final museum = store.save('item', itemData(trip.id, '城市漫步 · 海港与集市'));
      final hotel = itemData(trip.id, '市中心酒店', type: '住宿');
      hotel['costs'] = [
        {
          'id': 'cost-1',
          'label': '两晚住宿',
          'amount': '200',
          'currency': 'EUR',
          'category': '住宿',
        },
      ];
      final stay = store.save('item', hotel);
      store.reorder(trip.id, 1, [plane.id, museum.id, stay.id]);
      final key = GlobalKey();
      Future<void> capture(String name) => tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          'work/previews/$name-$width.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: HowDoI(store: store, sync: sync),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('work/previews').createSync(recursive: true);
        File(
          'work/previews/home-$width.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('北京 → 赫尔辛基'));
      await tester.pumpAndSettle();
      expect(find.text('已预订'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          'work/previews/editor-$width.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('保存行程'));
      await tester.pumpAndSettle();
      expect(store.get(plane.id)!.data['fields']['startDate'], '2026-10-11');
      await tester.tap(find.byTooltip('预算'));
      await tester.pumpAndSettle();
      expect(find.text('200.00'), findsWidgets);
      await capture('budget');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      if (width == 1440) {
        await tester.tap(find.text('北京 → 赫尔辛基'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('选择出发时间'));
        await tester.pumpAndSettle();
        await capture('time');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('选择出发日期'));
        await tester.pumpAndSettle();
        await capture('calendar');
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关于 / 检查更新'));
        await tester.pumpAndSettle();
        await capture('about');
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('旅行操作：北欧旅行'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑旅行'));
        await tester.pumpAndSettle();
        await capture('settings');
      }
      if (width == 1440) {
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
      }
      if (width < 800) {
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('旅行总览'));
      await tester.pumpAndSettle();
      if (width < 800) {
        expect(find.byType(Drawer), findsNothing);
      }
      await capture('overview');
      await tester.scrollUntilVisible(
        find.text('预计预算 · 原币种'),
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await capture('overview-budget');
      if (width < 800) {
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('预备工作'));
      await tester.pumpAndSettle();
      if (width < 800) {
        expect(find.byType(Drawer), findsNothing);
      }
      await capture('preparations');
      await tester.tap(find.text('检查护照有效期'));
      await tester.pumpAndSettle();
      await capture('preparation-editor');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    });
  }
}
