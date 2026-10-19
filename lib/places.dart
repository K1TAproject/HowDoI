import 'map_links.dart';
import 'planner.dart';

List<String> placeSlots(Map<String, dynamic> d) =>
    isTransport(d['type']) ? ['origin', 'destination'] : ['place'];
String placeText(Map<String, dynamic> d, String slot) => slot != 'place'
    ? fieldText(d, slot).trim()
    : [
        d['name'] ?? '',
        fieldText(d, 'address'),
      ].where((s) => s.toString().trim().isNotEmpty).join(' · ').trim();
Map<String, dynamic>? locationBinding(Map<String, dynamic> d, String slot) {
  final p = (d['locations'] as Map?)?[slot];
  return p == null ? null : Map<String, dynamic>.from(p);
}

Map<String, dynamic>? linkedPlace(Map<String, dynamic> d, String slot) {
  final p = locationBinding(d, slot);
  return p == null || p.containsKey('url') ? null : p;
}

bool placeStale(Map<String, dynamic> d, String slot) =>
    locationBinding(d, slot) != null &&
    locationBinding(d, slot)!['sourceText'] != placeText(d, slot);

bool hasPlace(Map<String, dynamic> d, String slot) =>
    placeText(d, slot).isNotEmpty ||
    (!placeStale(d, slot) && locationBinding(d, slot) != null);

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

String coordinates(Map<String, dynamic> p) => '${p['lat']},${p['lon']}';
Uri navigationUri(
  String provider,
  Map<String, dynamic> d,
  String slot, {
  bool route = false,
  bool web = false,
}) {
  if (route) slot = 'destination';
  final p = placeStale(d, slot) ? null : linkedPlace(d, slot);
  final from = placeStale(d, 'origin') ? null : linkedPlace(d, 'origin');
  final text = placeText(d, slot);
  final dest = p == null ? text : coordinates(p);
  final origin = from == null ? placeText(d, 'origin') : coordinates(from);
  if (provider == 'amap') {
    return mapSearchUri(provider, p?['name'] ?? text, p?['address'] ?? '');
  }
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
