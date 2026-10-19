import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:howdoi/main.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets('Flight key fields, pickers and unsaved switch protection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = Store(':memory:');
    final sync = SyncService(store, host: true);
    final trip = store.save('trip', tripData());
    final flight = store.save('item', {
      ...itemData(trip.id, '', type: '航班'),
      'fields': {
        'origin': '上海浦东',
        'destination': '巴黎',
        'number': 'MU示例',
        'terminalFrom': 'T1',
        'terminalTo': 'T2',
        'seat': '8A',
      },
    });
    await tester.pumpWidget(HowDoI(store: store, sync: sync));
    await tester.pumpAndSettle();
    expect(find.text('上海浦东 → 巴黎'), findsOneWidget);
    expect(find.text('MU示例'), findsOneWidget);
    expect(find.textContaining('T1'), findsOneWidget);
    expect(find.textContaining('8A'), findsNothing);
    await tester.tap(find.text('上海浦东 → 巴黎'));
    await tester.pumpAndSettle();
    expect(find.text('选择时区'), findsNothing);
    await tester.tap(find.byTooltip('选择出发时间'));
    await tester.pumpAndSettle();
    expect(find.text('选择时间 · 24 小时制'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final closeReply = Completer<bool>();
    const codec = StandardMethodCodec();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'howdoi/window',
      codec.encodeMethodCall(const MethodCall('requestClose')),
      (data) {
        closeReply.complete(codec.decodeEnvelope(data!) as bool);
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('尚未保存的修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(await closeReply.future, false);
    await tester.tap(find.text('添加日期').first);
    await tester.pumpAndSettle();
    expect(find.text('尚未保存的修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择到达日期'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarDatePicker), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存行程'));
    await tester.pumpAndSettle();
    expect(store.get(flight.id)!.data['fields']['startTime'], '00:00');
    expect(store.get(flight.id)!.data['fields']['seat'], '8A');
    expect(store.get(flight.id)!.data['name'], '');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    store.dispose();
  });
  testWidgets('Create an undated trip from the empty application', (
    tester,
  ) async {
    final store = Store(':memory:');
    final sync = SyncService(store, host: true);
    await tester.pumpWidget(HowDoI(store: store, sync: sync));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建第一次旅行'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '周末出游');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.trips.single.data['name'], '周末出游');
    expect(store.trips.single.data['start'], '');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    store.dispose();
  });
  testWidgets(
    'add dates only selects persistent days, items belong to selection, about shows version',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', {...tripData(), 'start': ''});
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      expect(find.text('待安排'), findsNothing);
      expect(find.text('添加行程'), findsNothing);
      await tester.tap(find.text('添加日期'));
      await tester.pumpAndSettle();
      expect(store.visibleDays(trip.id), [1]);
      expect(find.text('保存行程'), findsNothing);
      expect(store.items(trip.id), isEmpty);
      await tester.tap(find.text('添加日期'));
      await tester.pumpAndSettle();
      expect(store.visibleDays(trip.id), [1, 2]);
      await tester.tap(find.text('添加行程'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '第二天散步');
      await tester.tap(find.byTooltip('关于 / 检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存行程'));
      await tester.pumpAndSettle();
      expect(store.items(trip.id).single.data['day'], 2);
      await tester.tap(find.byTooltip('关于 / 检查更新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前版本：v0.1.14'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('检查更新'))).brightness,
        Brightness.dark,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
  testWidgets(
    'one-time history allocation is accessible and disappears when resolved',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', {...tripData(), 'start': ''});
      final item = store.save('item', itemData(trip.id, '老记录', day: 0));
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      expect(find.text('待安排'), findsNothing);
      await tester.tap(find.text('为 1 条历史行程分配日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('老记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 天').last);
      await tester.pumpAndSettle();
      expect(store.get(item.id)!.data['day'], 1);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('为 1 条历史行程分配日期'), findsNothing);
      expect(find.text('老记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
  testWidgets(
    'card menus do not select their target; blank deletion chooses neighbor and undo restores',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final a = store.save('trip', {...tripData(), 'name': 'A', 'start': ''});
      final b = store.save('trip', {...tripData(), 'name': 'B', 'start': ''});
      store.addDay(a);
      store.addDay(a);
      store.addDay(b);
      store.setSetting('selectedTrip', a.id);
      store.setSetting('selectedDay', '1');
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('旅行操作：B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑旅行'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'B',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.setting('selectedTrip'), a.id);
      await tester.tap(find.byTooltip('日期操作：第 2 天'));
      await tester.pumpAndSettle();
      expect(store.setting('selectedDay'), '1');
      await tester.tap(find.text('删除日期'));
      await tester.pumpAndSettle();
      expect(store.visibleDays(a.id), [1]);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(store.visibleDays(a.id), [1, 2]);
      expect(store.setting('selectedDay'), '2');
      await tester.tap(find.byTooltip('日期操作：第 2 天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除日期'));
      await tester.pumpAndSettle();
      expect(store.setting('selectedDay'), '1');
      await tester.tap(find.byTooltip('日期操作：第 1 天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除日期'));
      await tester.pumpAndSettle();
      expect(store.visibleDays(a.id), isEmpty);
      expect(find.text('添加行程'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
  testWidgets('resize keeps the unsaved wide editor when changing layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = Store(':memory:');
    final sync = SyncService(store, host: true);
    final trip = store.save('trip', tripData());
    store.addDay(trip);
    await tester.pumpWidget(HowDoI(store: store, sync: sync));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加行程'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '窗口变化仍保留');
    tester.view.physicalSize = const Size(900, 720);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '窗口变化仍保留',
    );
    tester.view.physicalSize = const Size(1440, 960);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存行程'));
    await tester.pumpAndSettle();
    expect(store.items(trip.id).single.data['name'], '窗口变化仍保留');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    store.dispose();
  });
  testWidgets(
    'nonempty day defaults to move, destructive path requires a second confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', {...tripData(), 'start': ''});
      final item = store.save('item', itemData(trip.id, '受影响的行程'));
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('日期操作：第 1 天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除日期'));
      await tester.pumpAndSettle();
      expect(find.text('将当天行程移到另一日后删除日期'), findsOneWidget);
      expect(find.text('当天开始的行程：1 条'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除当天行程及日期').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续删除…'));
      await tester.pumpAndSettle();
      expect(find.text('再次确认删除 1 条行程'), findsOneWidget);
      expect(store.get(item.id)!.deleted, false);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(store.get(item.id)!.deleted, true);
      expect(store.visibleDays(trip.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
  for (final size in [
    const Size(1440, 960),
    const Size(900, 720),
    const Size(390, 844),
  ]) {
    testWidgets('Create and edit itinerary at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      final trip = store.save('trip', tripData());
      store.save('item', itemData(trip.id, '初始景点'));
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      expect(find.text('初始景点'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(store.items(trip.id).single.data['done'], true);
      await tester.tap(find.text('添加行程').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '新增地点');
      await tester.tap(find.text('保存行程'));
      await tester.pumpAndSettle();
      expect(store.items(trip.id).length, 2);
      expect(find.text('新增地点'), findsOneWidget);
      await tester.tap(find.text('初始景点'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '尚未保存的本地名称');
      final original = store
          .items(trip.id)
          .firstWhere((r) => r.data['name'] == '初始景点');
      store.save('item', {
        ...original.data,
        'name': '另一设备的新名称',
      }, id: original.id);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存行程'));
      await tester.pumpAndSettle();
      expect(store.get(original.id)!.data['name'], '另一设备的新名称');
      expect(find.textContaining('活动已在其他设备修改'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    });
  }
}
