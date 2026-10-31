import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/day_map.dart';
import 'package:howdoi/planner.dart';
import 'package:howdoi/store.dart';
import 'core_test.dart' show tripData, itemData;
import 'coordinates016_test.dart' show bound, TestTiles;

void main() {
  setUpAll(tz.initializeTimeZones);
  for (final config in [
    (TargetPlatform.windows, 1100.0, false),
    (TargetPlatform.windows, 700.0, true),
    (TargetPlatform.android, 390.0, false),
  ]) {
    testWidgets(
      'red pins keep anchor, group exact coordinates and retain actions $config',
      (t) async {
        t.view.physicalSize = Size(config.$2, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        addTearDown(s.dispose);
        final trip = s.save('trip', tripData());
        final flight = s.save('item', {
          ...itemData(trip.id, '交通', type: '交通/移动'),
          'fields': {'origin': '车站', 'destination': '车站'},
          'locations': {'origin': bound('车站'), 'destination': bound('车站')},
        });
        final activity = s.save('item', {
          ...itemData(trip.id, '活动'),
          'activityPlaces': [
            {'id': 'a', 'name': '车站', 'binding': bound('车站')},
            {
              'id': 'b',
              'name': '车站',
              'binding': {
                ...bound('车站'),
                'position': {
                  ...bound('车站')['position'],
                  'lat': 40.828278925867995,
                },
              },
            },
          ],
        });
        final before = s.export();
        final edited = <String>[];
        final opened = <String>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          opened.add((call.arguments as Map)['url']);
          return true;
        });
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final capture = GlobalKey();
        final map = DayMap(
          nodes: [PlanNode(flight, 1), PlanNode(activity, 1)],
          onItem: (r) => edited.add(r.id),
          tileProvider: TestTiles(),
          fillWindow: config.$3,
        );
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: config.$1),
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: config.$3 ? map : SingleChildScrollView(child: map),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final pins = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is MapPinPainter,
        );
        final layer = t.widget<MarkerLayer>(find.byType(MarkerLayer));
        expect(layer.markers.length, 2);
        for (final marker in layer.markers) {
          expect(marker.alignment, Alignment.topCenter);
          expect(marker.width, 48);
          expect(marker.height, 48);
        }
        expect(
          find.descendant(
            of: find.byType(MarkerLayer),
            matching: find.byType(Text),
          ),
          findsNothing,
        );
        final controller = MapController.of(
          t.element(find.byType(MarkerLayer)),
        );
        for (final zoom in [8.0, 15.0, 19.0]) {
          controller.move(layer.markers.first.point, zoom);
          await t.pumpAndSettle();
          expect(t.getSize(pins.first), const Size(28, 28));
          final target =
              t.getTopLeft(find.byType(FlutterMap)) +
              controller.camera.latLngToScreenOffset(layer.markers.first.point);
          expect(
            (t.getBottomLeft(pins.first) + const Offset(14, 0) - target)
                .distance,
            lessThan(.01),
          );
        }
        // Transparent hit target above the painted pin remains tappable.
        final button = find
            .ancestor(of: pins.first, matching: find.byType(TextButton))
            .first;
        expect(t.getSize(button), const Size(48, 48));
        await t.tapAt(t.getTopLeft(button) + const Offset(3, 3));
        await t.pumpAndSettle();
        expect(find.text('此处有 3 次到访'), findsOneWidget);
        expect(find.textContaining('起点'), findsOneWidget);
        expect(find.textContaining('终点'), findsOneWidget);
        final rows = t.widgetList<ListTile>(find.byType(ListTile)).toList();
        expect(rows.map((w) => (w.title as Text).data), [
          '1. 车站',
          '2. 车站',
          '3. 车站',
        ]);
        for (var i = 0; i < 3; i++) {
          await t.tap(find.text('打开原地图').at(i));
          await t.pumpAndSettle();
        }
        expect(opened.length, 3);
        await t.tap(find.text('编辑').last);
        await t.pumpAndSettle();
        expect(edited, [activity.id]);
        for (var i = 0; i < 2; i++) {
          await t.tap(pins.first);
          await t.pumpAndSettle();
          await t.tap(find.text('编辑').at(i));
          await t.pumpAndSettle();
        }
        expect(edited, [activity.id, flight.id, flight.id]);
        final style = t.widget<TextButton>(button).style!;
        expect(style.side!.resolve({WidgetState.focused})!.width, 2);
        expect(style.overlayColor!.resolve({WidgetState.hovered}), isNotNull);
        Focus.of(t.element(pins.first)).requestFocus();
        await t.pumpAndSettle();
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(find.text('此处有 3 次到访'), findsOneWidget);
        await t.tap(find.text('关闭'));
        await t.pumpAndSettle();
        await t.tap(find.text('显示全部地点'));
        await t.pumpAndSettle();
        await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory('work/previews').createSync(recursive: true);
          File(
            'work/previews/pins021-${config.$2.toInt()}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(s.export(), before);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
