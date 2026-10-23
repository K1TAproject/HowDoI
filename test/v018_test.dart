import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/store.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/editors.dart';
import 'package:howdoi/overview.dart';
import 'core_test.dart' show tripData, itemData;
import 'coordinates016_test.dart' show bound;

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'frequency is trip scoped, stable ties and sync; summary deduplicates only original records',
    () {
      final s = Store(':memory:'), peer = Store(':memory:');
      addTearDown(s.dispose);
      addTearDown(peer.dispose);
      final a = s.save('trip', {...tripData(), 'start': ''}),
          b = s.save('trip', tripData());
      final flight = s.save('item', {
        ...itemData(a.id, '', type: '航班'),
        'endDay': 2,
        'fields': {
          'origin': 'A',
          'destination': 'B',
          'startTime': '22:00',
          'endTime': '01:00',
          'number': 'AB123',
        },
      });
      final hotel = s.save('item', {
        ...itemData(a.id, '酒店', type: '住宿', day: 2),
        'endDay': 5,
      });
      s.save('item', itemData(b.id, '1', type: '餐饮'));
      s.save('item', itemData(b.id, '2', type: '餐饮'));
      expect(s.frequentTypes(a.id).take(2), ['住宿', '航班']);
      expect(s.frequentTypes(b.id).first, '餐饮');
      final revisit = s.save('item', itemData(a.id, '酒店', type: '住宿', day: 7));
      final data = TripOverviewData(s, a), before = s.export();
      final summary = data.summaryByDay.values.expand((n) => n).toList();
      expect(summary.map((n) => n.item.id), [flight.id, hotel.id, revisit.id]);
      expect(s.export(), before);
      expect(overviewItemDetail(a, summary[1]), contains('3 晚'));
      expect(overviewItemDetail(a, summary[0]), contains('第 2 天'));
      s.remove(hotel);
      s.remove(revisit);
      expect(s.frequentTypes(a.id).first, '航班');
      s.save('item', {...flight.data, 'type': '餐饮'}, id: flight.id);
      expect(s.frequentTypes(a.id).first, '餐饮');
      peer.merge(decodeRecords(s.export(sync: true), format: 'howdoi-sync'));
      expect(peer.frequentTypes(a.id), s.frequentTypes(a.id));
      final empty = s.save('trip', tripData());
      expect(s.frequentTypes(empty.id).first, '游览/活动');
    },
  );
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'draft defaults and open menu remain stable after sync $platform',
      (t) async {
        final s = Store(':memory:'), remote = Store(':memory:');
        final trip = s.save('trip', tripData());
        final hotel = s.save('item', itemData(trip.id, '酒店', type: '住宿'));
        final key = GlobalKey<ItemEditorState>();
        Widget page() => MaterialApp(
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
        );
        await t.pumpWidget(page());
        await t.pumpAndSettle();
        expect(key.currentState!.value()['type'], '住宿');
        await t.tap(find.byTooltip('选择活动类型'));
        await t.pumpAndSettle();
        List<String> options() => t
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .map((w) => w.value!)
            .toList();
        final initial = options();
        expect(initial.first, '住宿');
        remote.merge(
          decodeRecords(s.export(sync: true), format: 'howdoi-sync'),
        );
        for (var i = 0; i < 3; i++) {
          remote.save('item', itemData(trip.id, '火车$i', type: '铁路'));
        }
        s.merge(
          decodeRecords(remote.export(sync: true), format: 'howdoi-sync'),
        );
        await t.pumpWidget(page());
        await t.pumpAndSettle();
        expect(options(), initial);
        expect(key.currentState!.value()['type'], '住宿');
        await t.tap(find.text('住宿').last);
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('选择活动类型'));
        await t.pumpAndSettle();
        expect(options().first, '铁路');
        await t.tap(find.text('住宿').last);
        await t.pumpAndSettle();
        final before = s.export();
        await t.pumpWidget(const SizedBox());
        expect(s.export(), before);
        final next = GlobalKey<ItemEditorState>();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ItemEditor(
                key: next,
                store: s,
                trip: trip,
                day: 1,
                onClose: () {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(next.currentState!.value()['type'], '铁路');
        await t.pumpWidget(const SizedBox());
        final edit = GlobalKey<ItemEditorState>();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ItemEditor(
                key: edit,
                store: s,
                trip: trip,
                item: hotel,
                day: 1,
                onClose: () {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(edit.currentState!.value()['type'], '住宿');
        await t.pumpWidget(const SizedBox());
        s.dispose();
        remote.dispose();
      },
    );
    testWidgets(
      'continuous overview original links, long places and separate edit $platform',
      (t) async {
        t.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 1440,
          900,
        );
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final s = Store(':memory:');
        final trip = s.save('trip', {...tripData(), 'start': ''});
        const long = 'Mount Moiwa Ropeway Entrance 很长的地点名称不会截断';
        final r = s.save('item', {
          ...itemData(trip.id, '札幌市内观光'),
          'activityPlaces': [
            {'id': 'a', 'name': long, 'binding': bound(long)},
            {'id': 'b', 'name': '北海道神宫'},
          ],
        });
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
        var edits = 0, day = 0, prep = 0;
        final before = s.export();
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: TripOverview(
                store: s,
                trip: trip,
                onItem: (item) {
                  expect(item.id, r.id);
                  edits++;
                },
                onDay: (d) => day = d,
                onPreparations: () => prep++,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('札幌市内观光'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
        await t.tap(find.text(long));
        await t.pumpAndSettle();
        expect(opened, [bound(long)['url']]);
        expect(edits, 0);
        expect(find.text('搜索地点 · 北海道神宫'), findsOneWidget);
        await t.tap(find.byTooltip('编辑行程'));
        await t.pumpAndSettle();
        expect(edits, 1);
        await t.tap(find.widgetWithText(TextButton, '第 1 天'));
        await t.pumpAndSettle();
        expect(day, 1);
        await t.tap(find.text('准备 0/0'));
        await t.pumpAndSettle();
        expect(prep, 1);
        expect(t.takeException(), isNull);
        expect(s.export(), before);
        await t.pumpWidget(const SizedBox());
        s.dispose();
      },
    );
  }
}
