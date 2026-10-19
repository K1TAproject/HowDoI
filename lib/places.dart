import 'dart:convert';
import 'model.dart';
import 'map_links.dart';
import 'planner.dart';

bool multiPlace(Map<String, dynamic> d) => ['游览', '游览/活动'].contains(d['type']);
List<Map<String, dynamic>> activityPlaces(Map<String, dynamic> d) {
  if (d['activityPlaces'] is List) {
    return [for (final p in d['activityPlaces']) Map<String, dynamic>.from(p)];
  }
  final oldText = [
    d['name'] ?? '',
    fieldText(d, 'address'),
  ].where((s) => s.toString().trim().isNotEmpty).join(' · ').trim();
  final address = fieldText(d, 'address').trim();
  final text = address.isNotEmpty
      ? address
      : (d['name'] as String? ?? '').trim();
  final original = (d['locations'] as Map?)?['place'];
  final binding = original == null
      ? null
      : <String, dynamic>{
          ...original,
          if (original['sourceText'] == oldText) 'sourceText': text,
        };
  return text.isEmpty && binding == null
      ? []
      : [
          {
            'id': 'legacy-place',
            'name': text,
            'binding': ?binding,
            if ((d['noReuse'] as Map?)?['place'] == true) 'reuseBlocked': true,
          },
        ];
}

List<String> placeSlots(Map<String, dynamic> d) => isTransport(d['type'])
    ? ['origin', 'destination']
    : multiPlace(d)
    ? [for (final p in activityPlaces(d)) 'activity:${p['id']}']
    : ['place'];
String placeText(Map<String, dynamic> d, String slot) {
  if (slot.startsWith('activity:')) {
    return activityPlaces(d)
            .where((p) => 'activity:${p['id']}' == slot)
            .firstOrNull?['name']
            ?.trim() ??
        '';
  }
  return slot != 'place'
      ? fieldText(d, slot).trim()
      : [
          d['name'] ?? '',
          fieldText(d, 'address'),
        ].where((s) => s.toString().trim().isNotEmpty).join(' · ').trim();
}

Map<String, dynamic>? locationBinding(Map<String, dynamic> d, String slot) {
  final p = slot.startsWith('activity:')
      ? (activityPlaces(
          d,
        ).where((p) => 'activity:${p['id']}' == slot).firstOrNull?['binding'])
      : (d['locations'] as Map?)?[slot];
  return p == null ? null : Map<String, dynamic>.from(p);
}

void setBinding(
  Map<String, dynamic> d,
  String slot,
  Map<String, dynamic>? binding, {
  bool blockReuse = false,
}) {
  if (slot.startsWith('activity:')) {
    final points = activityPlaces(d);
    final point = points
        .where((p) => 'activity:${p['id']}' == slot)
        .firstOrNull;
    if (point == null) throw const FormatException('地点已移除，请重新选择');
    if (binding == null) {
      point.remove('binding');
    } else {
      point['binding'] = binding;
    }
    point['reuseBlocked'] = blockReuse;
    d['activityPlaces'] = points;
    final old = Map<String, dynamic>.from(d['locations'] as Map? ?? {});
    old.remove('place');
    d['locations'] = old;
  } else {
    final locations = Map<String, dynamic>.from(d['locations'] as Map? ?? {});
    if (binding == null) {
      locations.remove(slot);
    } else {
      locations[slot] = binding;
    }
    d['locations'] = locations;
    d['noReuse'] = {...?d['noReuse'] as Map?, slot: blockReuse};
  }
}

bool reuseBlocked(Map<String, dynamic> d, String slot) =>
    slot.startsWith('activity:')
    ? (activityPlaces(d)
              .where((p) => 'activity:${p['id']}' == slot)
              .firstOrNull?['reuseBlocked'] ==
          true)
    : (d['noReuse'] as Map?)?[slot] == true;

Map<String, dynamic>? linkedPlace(Map<String, dynamic> d, String slot) {
  final p = locationBinding(d, slot);
  return p == null || p.containsKey('url') ? null : p;
}

bool placeStale(Map<String, dynamic> d, String slot) =>
    locationBinding(d, slot) != null &&
    locationBinding(d, slot)!['sourceText'] != placeText(d, slot);

bool hasPlace(Map<String, dynamic> d, String slot) =>
    placeText(d, slot).isNotEmpty || locationBinding(d, slot) != null;

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
        : placeSlots(d);
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

String bindingIdentity(Map<String, dynamic> p) => p['url'] is String
    ? '${p['provider']}:${p['url']}'
    : '${p['provider']}:${p['crs']}:${p['lat']}:${p['lon']}';
Map<String, List<Map<String, dynamic>>> reusableBindings(
  Iterable<Map<String, dynamic>> records,
) {
  final grouped = <String, Map<String, Map<String, dynamic>>>{};
  for (final d in records) {
    for (final slot in placeSlots(d)) {
      final name = placeText(d, slot).trim(), p = locationBinding(d, slot);
      if (name.isEmpty || p == null || placeStale(d, slot)) continue;
      grouped.putIfAbsent(name, () => {})[bindingIdentity(p)] = p;
    }
  }
  return {for (final e in grouped.entries) e.key: e.value.values.toList()};
}

class PlaceReusePlan {
  final Map<String, dynamic> current;
  final Map<String, Map<String, dynamic>> others = {};
  final List<String> affected = [];
  int count = 0;
  PlaceReusePlan(
    Iterable<Record> records,
    Map<String, dynamic> draft,
    String? itemId,
  ) : current = jsonDecode(jsonEncode(draft)) {
    final peers = records
        .where(
          (r) =>
              !r.deleted &&
              r.kind == 'item' &&
              r.data['trip'] == draft['trip'] &&
              r.id != itemId,
        )
        .toList();
    final candidates = reusableBindings([current, ...peers.map((r) => r.data)]);
    final uncertain = <String>{};
    for (final d in [current, ...peers.map((r) => r.data)]) {
      for (final slot in placeSlots(d)) {
        if (locationBinding(d, slot) != null && placeStale(d, slot)) {
          uncertain.add(placeText(d, slot));
        }
      }
    }
    void fill(Map<String, dynamic> d, String label) {
      for (final slot in placeSlots(d)) {
        if (locationBinding(d, slot) != null || reuseBlocked(d, slot)) continue;
        final name = placeText(d, slot), found = candidates[name] ?? [];
        if (found.length != 1 || uncertain.contains(name)) continue;
        setBinding(d, slot, {...found.single, 'sourceText': name});
        count++;
        affected.add('$label · $name');
      }
    }

    fill(current, '当前行程');
    for (final r in peers) {
      final d = Map<String, dynamic>.from(jsonDecode(jsonEncode(r.data)));
      final before = count;
      fill(d, itemTitle(r.data));
      if (count != before) others[r.id] = d;
    }
  }
}
