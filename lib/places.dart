import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'model.dart';
import 'planner.dart';
import 'store.dart';

const mapAgent = 'HowDoI (+https://github.com/K1TAproject/HowDoI)';
const searchEndpoint = 'https://nominatim.openstreetmap.org/search';

List<String> placeSlots(Map<String, dynamic> d) =>
    isTransport(d['type']) ? ['origin', 'destination'] : ['place'];
String placeText(Map<String, dynamic> d, String slot) => slot != 'place'
    ? fieldText(d, slot).trim()
    : [
        d['name'] ?? '',
        fieldText(d, 'address'),
      ].where((s) => s.toString().trim().isNotEmpty).join(' · ').trim();
Map<String, dynamic>? linkedPlace(Map<String, dynamic> d, String slot) {
  final p = (d['locations'] as Map?)?[slot];
  return p == null ? null : Map<String, dynamic>.from(p);
}

bool placeStale(Map<String, dynamic> d, String slot) =>
    linkedPlace(d, slot) != null &&
    linkedPlace(d, slot)!['sourceText'] != placeText(d, slot);

bool hasPlace(Map<String, dynamic> d, String slot) =>
    placeText(d, slot).isNotEmpty ||
    (!placeStale(d, slot) && linkedPlace(d, slot) != null);

String navigationSlot(PlanNode node) {
  final d = node.item.data;
  if (!isTransport(d['type'])) return 'place';
  if (node.end) return 'destination';
  if (d['type'] == '租车' ||
      (scheduledTransport(d['type']) && d['endDay'] > d['day'])) {
    return 'origin';
  }
  return 'destination';
}

class MapVisit {
  final PlanNode node;
  final String slot;
  MapVisit(this.node, this.slot);
  Map<String, dynamic>? get place => linkedPlace(node.item.data, slot);
  bool get stale => placeStale(node.item.data, slot);
  String get label => place?['name'] ?? placeText(node.item.data, slot);
}

List<MapVisit> mapVisits(Iterable<PlanNode> nodes, {bool daily = false}) {
  final result = <MapVisit>[];
  final seen = <String>{};
  for (final n in nodes) {
    final d = n.item.data;
    if (d['type'] == '住宿' && n.end) continue;
    final slots = isTransport(d['type'])
        ? n.end
              ? ['destination']
              : [
                  'origin',
                  if (d['type'] != '租车' &&
                      (d['endDay'] == d['day'] ||
                          d['endDay'] == 0 ||
                          !scheduledTransport(d['type'])))
                    'destination',
                ]
        : ['place'];
    for (final slot in slots) {
      // Whole-trip stays appear once; daily maps reference the original record.
      final key = '${n.item.id}:$slot';
      if (!seen.add(key)) continue;
      if (!daily &&
          !isTransport(d['type']) &&
          (n.end || n.stay && n.day != d['day'])) {
        continue;
      }
      result.add(MapVisit(n, slot));
    }
  }
  return result;
}

class PlaceSearch {
  static bool _busy = false;
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  final Store store;
  PlaceSearch(this.store);
  Future<List<Map<String, dynamic>>> search(String query) async {
    query = query.trim();
    if (query.isEmpty || query.length > 300) {
      throw const FormatException('请填写地点名称和城市，最多 300 字');
    }
    final endpoint = Uri.parse(
      store.setting('mapSearchEndpoint') ?? searchEndpoint,
    );
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw const FormatException('搜索服务必须使用无账号信息的 HTTPS 地址');
    }
    final key = 'mapSearch:${sha256.convert(utf8.encode('$endpoint\n$query'))}';
    final cached = store.setting(key);
    if (cached != null) {
      return (jsonDecode(cached) as List)
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
    }
    if (_busy || DateTime.now().isBefore(_blockedUntil)) {
      throw const FormatException('搜索正在进行或服务暂时限流，请稍后重试');
    }
    _busy = true;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final gap = DateTime.now().difference(_last);
      if (gap < const Duration(milliseconds: 1100)) {
        await Future<void>.delayed(const Duration(milliseconds: 1100) - gap);
      }
      _last = DateTime.now();
      final req = await client
          .getUrl(
            endpoint.replace(
              queryParameters: {
                'q': query,
                'format': 'jsonv2',
                'limit': '6',
                'addressdetails': '1',
              },
            ),
          )
          .timeout(const Duration(seconds: 15));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, mapAgent);
      final response = await req.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        if (response.statusCode == 429 || response.statusCode == 503) {
          final seconds =
              int.tryParse(response.headers.value('retry-after') ?? '') ?? 60;
          _blockedUntil = DateTime.now().add(
            Duration(seconds: seconds < 60 ? 60 : seconds),
          );
        }
        throw FormatException(
          '地点搜索暂不可用（HTTP ${response.statusCode}），可稍后重试或手动选点',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) throw const FormatException('搜索结果过大');
      }
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! List || raw.length > 20) {
        throw const FormatException('搜索结果格式无效');
      }
      final result = <Map<String, dynamic>>[];
      for (final p in raw) {
        final name = p['name'] as String? ?? '';
        final location = <String, dynamic>{
          'name': name.isEmpty ? p['display_name'] : name,
          'address': p['display_name'],
          'lat': double.parse(p['lat']),
          'lon': double.parse(p['lon']),
          'crs': 'WGS84',
          'provider': 'osm',
          'id': '${p['osm_type']}/${p['osm_id']}',
          'sourceText': '',
          'country': p['address']?['country_code'] ?? '',
        };
        validateLocations({'place': location});
        result.add(location);
      }
      store.setSetting(key, jsonEncode(result));
      return result;
    } finally {
      client.close(force: true);
      _busy = false;
    }
  }
}

String coordinates(Map<String, dynamic> p) => '${p['lat']},${p['lon']}';
Uri navigationUri(
  String provider,
  Map<String, dynamic> d,
  String slot, {
  bool route = false,
  bool web = false,
}) {
  final p = placeStale(d, slot) ? null : linkedPlace(d, slot);
  final from = placeStale(d, 'origin') ? null : linkedPlace(d, 'origin');
  final text = placeText(d, slot);
  final dest = p == null ? text : coordinates(p);
  final origin = from == null ? placeText(d, 'origin') : coordinates(from);
  if (provider == 'google') {
    return Uri.https(
      'www.google.com',
      p == null && !route ? '/maps/search/' : '/maps/dir/',
      {
        'api': '1',
        if (p == null && !route) 'query': text else 'destination': dest,
        if (route) 'origin': origin,
        if (!route && p != null) 'dir_action': 'navigate',
      },
    );
  }
  if (web) {
    // Text search avoids accidentally treating WGS84 as Baidu's default BD09.
    return Uri.https('api.map.baidu.com', '/geocoder', {
      'address': [
        p?['name'] ?? text,
        p?['address'] ?? '',
      ].where((s) => s.isNotEmpty).join(' '),
      'output': 'html',
      'src': 'webapp.k1taproject.howdoi',
    });
  }
  return Uri(
    scheme: 'baidumap',
    host: 'map',
    path: route
        ? '/direction'
        : p == null
        ? '/geocoder'
        : '/navi',
    queryParameters: {
      'src': 'andr.k1taproject.howdoi',
      'coord_type': 'wgs84',
      if (route) ...{
        'origin': origin,
        'destination': dest,
      } else if (p == null)
        'address': text
      else ...{
        'location': dest,
        'query': p['name'],
      },
    },
  );
}
