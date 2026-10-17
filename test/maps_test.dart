import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:howdoi/model.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/maps.dart';
import 'package:howdoi/overview.dart';

import 'package:howdoi/store.dart';
import 'package:howdoi/editors.dart';
import 'core_test.dart' show tripData, itemData;

Map<String, dynamic> place(String name, {String country = 'jp'}) => {
  'name': name,
  'address': 'Tokyo',
  'lat': 35.6812,
  'lon': 139.7671,
  'crs': 'WGS84',
  'provider': 'osm',
  'id': 'node/123',
  'sourceText': name,
  'country': country,
};

void main() {
  setUpAll(tz.initializeTimeZones);
  test('locations validate at import and remain optional for old backups', () {
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final trip = s.save('trip', tripData());
    final d = itemData(trip.id, '车站');
    validateData('item', d);
    for (final invalid in [double.nan, double.infinity, 91, '35']) {
      expect(
        () => validateData('item', {
          ...d,
          'locations': {
            'place': {...place('车站'), 'lat': invalid},
          },
        }),
        throwsFormatException,
      );
    }
    expect(
      () => validateData('item', {
        ...d,
        'locations': {
          'place': {...place('车站'), 'crs': 'BD09'},
        },
      }),
      throwsFormatException,
    );
    s.save('item', {
      ...d,
      'locations': {'place': place('车站')},
    });
    final exported = s.export();
    final copy = Store(':memory:');
    addTearDown(copy.dispose);
    copy.importCopy(decodeRecords(exported));
    expect(copy.items(copy.trips.single.id).single.data['locations'], {
      'place': place('车站'),
    });
    final old = jsonDecode(exported);
    old['version'] = 1;
    for (final r in old['records']) {
      (r['data'] as Map).remove('locations');
    }
    expect(decodeRecords(jsonEncode(old)), hasLength(s.all.length));
    s.setSetting('mapSearchEndpoint', 'https://example.invalid/search');
    expect(s.export(), isNot(contains('example.invalid')));
  });
  test(
    'cross-day flight, stays, repeat visits and unknown points preserve order',
    () {
      final s = Store(':memory:');
      addTearDown(s.dispose);
      final trip = s.save('trip', {...tripData(), 'start': ''});
      final flight = s.save('item', {
        ...itemData(trip.id, '', type: '航班'),
        'endDay': 2,
        'fields': {'origin': '北京', 'destination': '东京'},
        'locations': {
          'origin': place('北京', country: 'cn'),
          'destination': place('东京'),
        },
      });
      final hotel = s.save('item', {
        ...itemData(trip.id, '酒店', type: '住宿', day: 2),
        'endDay': 5,
        'locations': {'place': place('酒店')},
      });
      s.save('item', {
        ...itemData(trip.id, '东京', day: 6),
        'locations': {'place': place('东京')},
      });
      s.save('item', itemData(trip.id, '未定位', day: 7));
      s.save('item', itemData(trip.id, '历史', day: 0));
      final overview = TripOverviewData(s, trip);
      final visits = mapVisits([
        for (final day in [...overview.days, 0]) ...overview.byDay[day]!,
      ]);
      expect(visits.map((v) => v.label), ['北京', '东京', '酒店', '东京', '未定位', '历史']);
      expect(visits.where((v) => v.node.item.id == flight.id), hasLength(2));
      expect(visits.where((v) => v.node.item.id == hotel.id), hasLength(1));
      expect(
        mapVisits(overview.byDay[3]!, daily: true).single.node.item.id,
        hotel.id,
      );
      expect(s.items(trip.id), hasLength(5));
    },
  );
  test(
    'official URLs encode WGS84 and stale text never navigates to old coordinates',
    () {
      final d = {
        ...itemData('t', '', type: '航班'),
        'fields': {'origin': 'A & B', 'destination': '东京'},
        'locations': {'origin': place('A & B'), 'destination': place('东京')},
      };
      final baidu = navigationUri('baidu', d, 'destination');
      expect(baidu.scheme, 'baidumap');
      expect(baidu.queryParameters['coord_type'], 'wgs84');
      expect(baidu.queryParameters['location'], '35.6812,139.7671');
      expect(
        navigationUri(
          'baidu',
          d,
          'destination',
          web: true,
        ).queryParameters['address'],
        '东京 Tokyo',
      );
      final google = navigationUri('google', d, 'destination');
      expect(google.queryParameters.containsKey('origin'), false);
      expect(google.queryParameters.containsKey('query_place_id'), false);
      expect(
        navigationUri(
          'google',
          d,
          'destination',
          route: true,
        ).queryParameters['origin'],
        '35.6812,139.7671',
      );
      d['fields'] = {'origin': 'A & B', 'destination': '京都'};
      expect(placeStale(d, 'destination'), true);
      expect(
        navigationUri('google', d, 'destination').queryParameters['query'],
        '京都',
      );
      expect(
        navigationUri('baidu', d, 'destination').queryParameters['address'],
        '京都',
      );
      expect(
        navigationUri('baidu', d, 'destination', web: true).scheme,
        'https',
      );
    },
  );
  test(
    'sync merge preserves locations, tombstones and original record conflicts',
    () {
      final a = Store(':memory:'), b = Store(':memory:');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final trip = a.save('trip', tripData());
      final r = a.save('item', {
        ...itemData(trip.id, '东京'),
        'locations': {'place': place('东京')},
      });
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      expect(b.items(trip.id), hasLength(1));
      expect(b.get(r.id)!.data['locations'], r.data['locations']);
      final changed = b.save('item', {
        ...b.get(r.id)!.data,
        'locations': <String, dynamic>{},
      }, id: r.id);
      a.merge([changed]);
      expect(a.get(r.id)!.data['locations'], isEmpty);
      a.merge([
        Record(
          r.id,
          r.kind,
          r.device,
          changed.modified + 1,
          true,
          changed.data,
        ),
      ]);
      b.merge(decodeRecords(a.export(sync: true), format: 'howdoi-sync'));
      expect(b.items(trip.id), isEmpty);
    },
  );
  testWidgets(
    'editor retains optional location fields and checks stale text in draft',
    (t) async {
      final s = Store(':memory:');
      final trip = s.save('trip', tripData());
      final r = s.save('item', {
        ...itemData(trip.id, '东京'),
        'locations': {'place': place('东京')},
      });
      final key = GlobalKey<ItemEditorState>();
      await t.pumpWidget(
        MaterialApp(
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
      expect(key.currentState!.value()['locations'], r.data['locations']);
      key.currentState!.name.text = '京都';
      expect(placeStale(key.currentState!.value(), 'place'), true);
      expect(s.get(r.id)!.data['name'], '东京');
      expect(key.currentState!.save(close: false), true);
      expect(s.get(r.id)!.data['locations'], r.data['locations']);
      await t.pumpWidget(const SizedBox());
      s.dispose();
    },
  );
  testWidgets('empty map and external navigation dialog fit a narrow screen', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final s = Store(':memory:');
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => ListView(
              children: [
                TripMap(nodes: const [], onItem: (_) {}),
                TextButton(
                  onPressed: () => navigatePlace(c, s, itemData('t', '东京')),
                  child: const Text('打开导航'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开导航'));
    await t.pumpAndSettle();
    expect(find.textContaining('当前使用文字搜索'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('关闭'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    s.dispose();
  });
  test('explicit searches cache, serialize and handle HTTP failure', () async {
    final s = Store(':memory:');
    addTearDown(s.dispose);
    final fake = _Network();
    await HttpOverrides.runZoned(() async {
      final service = PlaceSearch(s);
      final first = await service.search('Tokyo Station');
      expect(first.single['id'], 'node/123');
      expect(await service.search('Tokyo Station'), first);
      expect(fake.client.requests.length, 1);
      await service.search('Eiffel Tower');
      expect(
        fake.client.times[1].difference(fake.client.times[0]).inMilliseconds,
        greaterThanOrEqualTo(1000),
      );
      fake.client.status = 429;
      await expectLater(
        service.search('Beijing Airport'),
        throwsFormatException,
      );
      await expectLater(service.search('Another'), throwsFormatException);
      expect(fake.client.requests, hasLength(3));
      expect(fake.client.agent, contains('github.com/K1TAproject/HowDoI'));
    }, createHttpClient: (_) => fake.client);
  });
}

class _Network {
  final client = _Client();
}

class _Client implements HttpClient {
  final requests = <Uri>[], times = <DateTime>[];
  int status = 200;
  String? agent;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requests.add(uri);
    times.add(DateTime.now());
    return _Request(this);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  final _Client client;
  _Headers(this.client);
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    if (name == HttpHeaders.userAgentHeader) client.agent = value.toString();
  }

  @override
  String? value(String name) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  final _Client client;
  _Request(this.client);
  @override
  HttpHeaders get headers => _Headers(client);
  @override
  Future<HttpClientResponse> close() async => _Response(client);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  final _Client client;
  _Response(this.client);
  @override
  int get statusCode => client.status;
  @override
  HttpHeaders get headers => _Headers(client);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.value(
        utf8.encode(
          jsonEncode([
            {
              'name': 'Test',
              'display_name': 'Test, Tokyo',
              'lat': '35',
              'lon': '139',
              'osm_type': 'node',
              'osm_id': 123,
              'address': {'country_code': 'jp'},
            },
          ]),
        ),
      ).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
