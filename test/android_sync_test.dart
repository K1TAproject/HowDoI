import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/main.dart';
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'core_test.dart' show tripData, itemData;

void main() {
  setUpAll(tz.initializeTimeZones);

  test(
    'cancelled identity verification never persists credentials or changes records',
    () async {
      HttpOverrides.global = null;
      final identity = makeIdentity(null);
      final security = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(identity['cert']!))
        ..usePrivateKeyBytes(utf8.encode(identity['key']!));
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        security,
      );
      final arrived = Completer<void>();
      server.listen((request) {
        if (!arrived.isCompleted) arrived.complete();
      });
      final store = Store(':memory:');
      final sync = SyncService(store, host: false);
      addTearDown(() async {
        sync.dispose();
        store.dispose();
        await server.close(force: true);
      });
      final before = store.export(sync: true);
      final attempt = sync.pair(
        jsonEncode({
          'app': 'howdoi-pair',
          'version': 1,
          'host': '127.0.0.1',
          'port': server.port,
          'fingerprint': identity['fingerprint'],
          'token': identity['token'],
        }),
      );
      final expectation = expectLater(attempt, throwsA(anything));
      await arrived.future.timeout(const Duration(seconds: 5));
      await sync.stop();
      await expectation;
      expect(store.setting('sync.peer'), isNull);
      expect(store.export(sync: true), before);
      expect(sync.status, contains('已关闭'));
    },
  );

  testWidgets(
    'Android root back closes drawer and protects quick preparation input; Windows host stays active',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = Store(':memory:');
      final sync = SyncService(store, host: true);
      store.save('trip', tripData());
      var exits = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exits, 0);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预备工作'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '未保存准备工作');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exits, 0);
      expect(find.textContaining('尚未'), findsWidgets);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(sync.active, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('pairing validation rejects arbitrary QR and incompatible payloads', () {
    for (final value in [
      'https://example.com',
      '{}',
      '{"app":"howdoi-pair","version":99}',
    ]) {
      expect(() => SyncService.parsePairing(value), throwsFormatException);
    }
  });

  test(
    'verified TLS pairing, offline merge, checklist, budgets, deletion and restore',
    () async {
      HttpOverrides.global = null;
      final directory = Directory.systemTemp.createTempSync(
        'howdoi-sync-test-',
      );
      final a = Store('${directory.path}/windows.db');
      var b = Store('${directory.path}/android.db');
      final host = SyncService(a, host: true, port: 0);
      var client = SyncService(b, host: false);
      addTearDown(() async {
        await client.stop();
        await host.stop();
        client.dispose();
        host.dispose();
        a.dispose();
        b.dispose();
        directory.deleteSync(recursive: true);
      });
      var trip = a.save('trip', {...tripData(), 'start': ''});
      a.savePreparations(trip, [
        {'id': 'passport', 'name': '护照', 'note': '', 'due': '', 'done': false},
      ]);
      trip = a.get(trip.id)!;
      final hotel = a.save('item', {
        ...itemData(trip.id, '旅馆', type: '住宿'),
        'locations': {
          'place': {
            'url': 'https://surl.amap.com/zjlG58usfdy',
            'provider': 'amap',
            'name': '旅馆',
            'address': '测试地址',
            'sourceText': '旅馆',
          },
        },
        'costs': [
          {
            'id': 'c',
            'label': '房费',
            'currency': 'EUR',
            'amount': '100',
            'category': '住宿',
          },
        ],
      });
      final flight = a.save('item', {
        ...itemData(trip.id, '跨日航班', type: '航班'),
        'endDay': 2,
      });
      final pairing = {
        ...jsonDecode(await host.pairingText()) as Map<String, dynamic>,
        'host': '127.0.0.1',
        'addresses': <String>[],
      };
      final initial = b.export(sync: true);
      await expectLater(
        client.pair(jsonEncode({...pairing, 'token': 'x' * 44})),
        throwsA(isA<HttpException>()),
      );
      expect(b.setting('sync.peer'), isNull);
      expect(b.export(sync: true), initial);
      await expectLater(
        client.pair(jsonEncode({...pairing, 'fingerprint': '0' * 64})),
        throwsA(isA<HandshakeException>()),
      );
      expect(b.setting('sync.peer'), isNull);
      await client.pair(jsonEncode(pairing));
      expect(client.status, startsWith('已同步'));
      expect(b.get(hotel.id)!.data['locations'], hotel.data['locations']);
      // The real HTTPS endpoint rejects protocol and clock mismatches before merging.
      for (final envelope in [
        {
          ...jsonDecode(b.export(sync: true)) as Map<String, dynamic>,
          'version': 99,
          'sentAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          ...jsonDecode(b.export(sync: true)) as Map<String, dynamic>,
          'sentAt': 0,
        },
      ]) {
        final beforeHost = a.export(sync: true);
        final http = HttpClient(
          context: SecurityContext(withTrustedRoots: false),
        );
        http.badCertificateCallback = (_, _, _) => true;
        try {
          final request = await http.postUrl(
            Uri.parse('https://127.0.0.1:${pairing['port']}/sync'),
          );
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${pairing['token']}',
          );
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(envelope));
          final response = await request.close();
          expect(response.statusCode, 409);
          await response.drain<void>();
          expect(a.export(sync: true), beforeHost);
        } finally {
          http.close(force: true);
        }
      }
      expect(b.visibleDays(trip.id), a.visibleDays(trip.id));
      expect(b.preparations(b.get(trip.id)!), a.preparations(trip));
      expect(
        Budget(trip, b.items(trip.id)).byCurrency['EUR'],
        BigInt.from(10000),
      );
      expect(b.export(), isNot(contains(pairing['token'])));
      expect(b.export(), isNot(contains(pairing['fingerprint'])));
      client.active = false;
      a.save('item', {...hotel.data, 'note': '电脑离线'}, id: hotel.id);
      b.save('item', {
        ...flight.data,
        'note': '手机离线',
        'locations': {
          'destination': {
            'url': 'https://maps.app.goo.gl/ytAHMqwsXXqTCoky5',
            'provider': 'google',
            'name': '目的地',
            'address': '',
            'sourceText': '',
          },
        },
      }, id: flight.id);
      client.active = true;
      await client.tick();
      expect(a.get(flight.id)!.data['note'], '手机离线');
      expect(
        a.get(flight.id)!.data['locations'],
        b.get(flight.id)!.data['locations'],
      );
      expect(b.get(hotel.id)!.data['note'], '电脑离线');
      // Whole-trip LWW also includes the preparation list.
      a.savePreparations(a.get(trip.id)!, [
        {'id': 'passport', 'name': '电脑清单', 'note': '', 'due': '', 'done': true},
      ]);
      b.savePreparations(b.get(trip.id)!, [
        {
          'id': 'passport',
          'name': '手机清单',
          'note': '',
          'due': '',
          'done': false,
        },
      ]);
      final expected = a.get(trip.id)!.newerThan(b.get(trip.id)!)
          ? a.get(trip.id)!
          : b.get(trip.id)!;
      await client.tick();
      expect(a.get(trip.id)!.data, expected.data);
      expect(b.get(trip.id)!.data, expected.data);
      await Future.wait([client.tick(), client.tick(), client.tick()]);
      expect(a.items(trip.id).length, 2);
      a.remove(a.get(flight.id)!);
      await client.tick();
      expect(b.get(flight.id)!.deleted, true);
      // Restart the client without clearing settings or re-pairing.
      client.dispose();
      b.dispose();
      b = Store('${directory.path}/android.db');
      client = SyncService(b, host: false);
      await client.restore();
      expect(client.status, startsWith('已同步'));
      expect(b.get(hotel.id)!.data['locations'], hotel.data['locations']);
      expect(client.lastSuccess, isNotNull);
      expect(b.items(trip.id).single.id, hotel.id);
      // Saved modifications trigger a real bidirectional sync automatically.
      b.save('item', {...b.get(hotel.id)!.data, 'note': '自动同步'}, id: hotel.id);
      for (var n = 0; n < 40 && a.get(hotel.id)!.data['note'] != '自动同步'; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(a.get(hotel.id)!.data['note'], '自动同步');
      while (client.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final before = b.export(sync: true);
      a.merge([
        Record(
          hotel.id,
          'item',
          'future',
          DateTime.now().microsecondsSinceEpoch + 600000000,
          false,
          hotel.data,
        ),
      ]);
      await client.tick();
      expect(client.status, contains('时间'));
      expect(client.status, isNot(startsWith('已同步')));
      expect(b.export(sync: true), before);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'phone editor: picker back, keyboard bounds, unsaved draft survives sync',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final store = Store(':memory:');
      final sync = SyncService(store, host: false);
      final trip = store.save('trip', tripData());
      final item = store.save('item', {
        ...itemData(trip.id, '', type: '航班'),
        'fields': {'origin': '上海', 'destination': '东京'},
      });
      await tester.pumpWidget(HowDoI(store: store, sync: sync));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上海 → 东京'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择出发时间'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('field-picker')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('field-picker')), findsNothing);
      expect(find.text('保存行程'), findsOneWidget);
      final origin = find.widgetWithText(TextField, '出发机场 *');
      // Locate the existing origin value rather than depending on translated labels.
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '上海',
      );
      expect(field, findsOneWidget, reason: '$origin');
      await tester.enterText(field, '草稿机场');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomRight(find.text('保存行程')).dy, lessThan(552));
      store.merge([
        Record(item.id, 'item', 'remote', item.modified + 1000, false, {
          ...item.data,
          'note': '远程修改',
        }),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('草稿机场'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(store.get(item.id)!.data['fields']['origin'], '上海');
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      store.dispose();
    },
  );
}
