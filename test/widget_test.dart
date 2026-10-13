import 'package:flutter/material.dart';
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
    expect(find.text('选择时间 · 24小时制'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待安排').first);
    await tester.pumpAndSettle();
    expect(find.text('尚未保存的修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择到达日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
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
  for (final size in [const Size(1440, 960), const Size(390, 844)]) {
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
