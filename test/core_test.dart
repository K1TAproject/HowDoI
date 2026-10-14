import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:howdoi/model.dart';
import 'package:howdoi/store.dart';
import 'package:howdoi/sync.dart';

Map<String, dynamic> tripData() => {
  'name': '北欧旅行',
  'days': 7,
  'start': '2026-10-11',
  'base': 'CNY',
  'zone': 'Asia/Shanghai',
  'note': '',
  'rates': {'EUR': '7.8'},
};
Map<String, dynamic> itemData(
  String trip,
  String name, {
  String type = '游览',
  int day = 1,
}) => {
  'trip': trip,
  'day': day,
  'endDay': type == '住宿' ? day + 2 : day,
  'name': name,
  'type': type,
  'note': '',
  'booking': '不适用',
  'done': false,
  'fields': <String, dynamic>{},
  'costs': <dynamic>[],
};

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('exact money, currency precision, rounding, unknown FX', () {
    expect(convertAmount('100', 'EUR', '7.8', 'CNY'), BigInt.from(78000));
    expect(convertAmount('0.01', 'EUR', '1.5', 'CNY'), BigInt.from(2));
    expect(() => decimalUnits('1.5', 0), throwsFormatException);
    expect(() => decimalUnits('-1', 2), throwsFormatException);
    final trip = Record('t', 'trip', 'a', 1, false, tripData());
    final item = itemData('t', '酒店', type: '住宿');
    item['costs'] = [
      {
        'id': '1',
        'label': '住宿',
        'amount': '100',
        'currency': 'EUR',
        'category': '住宿',
      },
      {
        'id': '2',
        'label': '门票',
        'amount': '8000',
        'currency': 'JPY',
        'category': '门票/活动',
      },
      {
        'id': '3',
        'label': '未定',
        'amount': '',
        'currency': 'CNY',
        'category': '其他',
      },
    ];
    final budget = Budget(trip, [Record('i', 'item', 'a', 1, false, item)]);
    expect(budget.total, BigInt.from(78000));
    expect(budget.pending['JPY'], BigInt.from(8000));
    expect(budget.unknown, 1);
  });
  test('invalid calendar dates are rejected', () {
    expect(() => parseDate('2026-02-30'), throwsFormatException);
  });
  test('LWW conflicts, independent changes, tombstones, deleted parents', () {
    final a = Store(':memory:'), b = Store(':memory:');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final t = a.save('trip', tripData());
    final i = a.save('item', itemData(t.id, '景点'));
    b.merge(a.all);
    a.save('item', {...i.data, 'name': '电脑修改'}, id: i.id);
    b.save('item', itemData(t.id, '手机新增'));
    b.merge(a.all);
    a.merge(b.all);
    expect(a.items(t.id).length, 2);
    expect(b.get(i.id)!.data['name'], '电脑修改');
    final first = Record(i.id, 'item', 'a', 100, false, i.data),
        second = Record(i.id, 'item', 'z', 100, false, {
          ...i.data,
          'name': 'tie',
        });
    expect(second.newerThan(first), isTrue);
    a.remove(a.get(i.id)!);
    b.merge(a.all);
    a.merge(b.all);
    expect(b.items(t.id).length, 1);
    a.remove(t);
    b.merge(a.all);
    expect(b.trips, isEmpty);
    expect(b.items(t.id), isEmpty);
    final generation = b.generation;
    b.merge(a.all);
    expect(b.generation, generation);
  });
  test(
    'SQLite reopen, copy import remaps links, bad input leaves data unchanged',
    () {
      final dir = Directory.systemTemp.createTempSync('howdoi-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      var a = Store('${dir.path}/test.db');
      final t = a.save('trip', tripData());
      final from = a.save('item', itemData(t.id, '机场'));
      final flight = itemData(t.id, '航班', type: '航班');
      flight['fields'] = {'fromId': from.id};
      flight['costs'] = [
        {
          'id': uuid.v4(),
          'label': '票',
          'amount': '0',
          'currency': 'CNY',
          'category': '交通',
        },
      ];
      a.save('item', flight);
      a.setSetting('sync.peer', 'private');
      a.dispose();
      a = Store('${dir.path}/test.db');
      addTearDown(a.dispose);
      final text = a.export();
      expect(text, isNot(contains('private')));
      final b = Store(':memory:');
      addTearDown(b.dispose);
      expect(b.importCopy(decodeRecords(text)), 1);
      expect(b.trips.single.id, isNot(t.id));
      final newItems = b.items(b.trips.single.id);
      final importedFlight = newItems.singleWhere(
        (r) => r.data['type'] == '航班',
      );
      expect(
        importedFlight.data['fields']['fromId'],
        newItems.singleWhere((r) => r.data['name'] == '机场').id,
      );
      final before = b.export();
      expect(
        () => decodeRecords(
          '{"format":"howdoi-backup","version":9,"records":[]}',
        ),
        throwsFormatException,
      );
      expect(b.export(), before);
      final list = a.all;
      expect(
        () => b.importCopy(list.where((r) => r.kind != 'trip').toList()),
        throwsFormatException,
      );
      expect(b.export(), before);
    },
  );
  test('reorder retains independently added items', () {
    final a = Store(':memory:');
    addTearDown(a.dispose);
    final t = a.save('trip', tripData());
    final x = a.save('item', itemData(t.id, 'A')),
        y = a.save('item', itemData(t.id, 'B'));
    a.reorder(t.id, 1, [y.id, x.id]);
    final z = a.save('item', itemData(t.id, 'C'));
    expect(a.timeline(t.id, 1).map((r) => r.id), [y.id, x.id, z.id]);
  });
  test('TLS sync, auth rejection, repeat, deletion and reconnection', () async {
    HttpOverrides.global = null;
    final a = Store(':memory:'), b = Store(':memory:');
    final server = SyncService(a, host: true, port: 0),
        client = SyncService(b, host: false);
    addTearDown(() async {
      await client.stop();
      await server.stop();
      client.dispose();
      server.dispose();
      a.dispose();
      b.dispose();
    });
    final t = a.save('trip', tripData());
    final i = a.save('item', itemData(t.id, '同步地点'));
    final pairing = Map<String, dynamic>.from(
      jsonDecode(await server.pairingText()),
    );
    pairing['host'] = '127.0.0.1';
    await client.pair(jsonEncode(pairing));
    expect(b.trips.length, 1, reason: client.status);
    expect(client.status, startsWith('已同步'));
    expect(server.status, startsWith('已同步'));
    b.save('item', {...b.get(i.id)!.data, 'note': '手机记录'}, id: i.id);
    await client.tick();
    expect(a.get(i.id)!.data['note'], '手机记录');
    await client.tick();
    expect(a.items(t.id).length, 1);
    a.remove(a.get(i.id)!);
    await client.tick();
    expect(b.items(t.id), isEmpty);
    await client.stop();
    a.save('item', itemData(t.id, '离线新增'));
    await client.start();
    expect(b.items(t.id).length, 1);
    client.peer!['token'] = 'incorrect';
    await client.tick();
    expect(client.status, contains('401'));
    client.peer!['fingerprint'] = '0' * 64;
    await client.tick();
    expect(client.status, isNot(startsWith('已同步')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
