import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'model.dart';
import 'planner.dart';

class Store extends ChangeNotifier {
  final Database db;
  late final String device;
  int generation = 0;
  Store(String path) : db = sqlite3.open(path) {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      'CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    if (setting('dataVersion') != '2') {
      if (path != ':memory:' &&
          db.select('SELECT id FROM records LIMIT 1').isNotEmpty) {
        final backup =
            '$path.pre-0.1.1-${DateTime.now().microsecondsSinceEpoch}.db';
        db.execute('VACUUM INTO ?', [backup]);
        setSetting('upgradeBackup', backup);
      }
      setSetting('dataVersion', '2');
    }
    device = setting('device') ?? uuid.v4();
    setSetting('device', device);
  }
  String? setting(String key) {
    final rows = db.select('SELECT value FROM settings WHERE key=?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) =>
      db.execute('INSERT OR REPLACE INTO settings VALUES (?,?)', [key, value]);
  List<Record> get all => db
      .select('SELECT json FROM records')
      .map((r) => Record.fromJson(jsonDecode(r['json'] as String)))
      .toList();
  Record? get(String id) {
    final rows = db.select('SELECT json FROM records WHERE id=?', [id]);
    return rows.isEmpty
        ? null
        : Record.fromJson(jsonDecode(rows.first['json'] as String));
  }

  List<Record> get trips =>
      all.where((r) => r.kind == 'trip' && !r.deleted).toList()
        ..sort((a, b) => b.modified.compareTo(a.modified));
  List<Record> items(String trip) => all
      .where(
        (r) =>
            r.kind == 'item' &&
            r.data['trip'] == trip &&
            !r.deleted &&
            get(trip)?.deleted == false,
      )
      .toList();
  List<Record> dayItems(String trip, int day) {
    final rows = items(trip).where((r) => r.data['day'] == day).toList();
    final ids = get('order:$trip:$day')?.data['ids'] as List? ?? [];
    rows.sort((a, b) {
      final x = ids.indexOf(a.id), y = ids.indexOf(b.id);
      if (x == -1 && y == -1) return a.id.compareTo(b.id);
      if (x == -1) return 1;
      if (y == -1) return -1;
      return x.compareTo(y);
    });
    return rows;
  }

  String zone(Record trip, int day) =>
      get('day:${trip.id}:$day')?.data['zone'] as String? ?? trip.data['zone'];
  List<int> visibleDays(String trip) => (planNodes(
    items(trip),
  ).map((n) => n.day).where((d) => d > 0).toSet().toList()..sort());
  List<PlanNode> timeline(String trip, int day) => orderedNodes(
    planNodes(items(trip)).where((n) => n.day == day && !n.stay).toList(),
    get('order:$trip:$day')?.data['ids'] as List? ?? [],
    timed: day != 0,
  );
  void _put(Record r) => db.execute(
    'INSERT OR REPLACE INTO records VALUES (?,?)',
    [r.id, jsonEncode(r.toJson())],
  );
  Record save(
    String kind,
    Map<String, dynamic> data, {
    String? id,
    bool deleted = false,
  }) {
    validateData(kind, data);
    final key = id ?? uuid.v4();
    final old = get(key);
    if (old != null && old.kind != kind) throw const FormatException('记录类型冲突');
    final tripId = kind == 'item' ? data['trip'] as String : null;
    final orders = <int, List<String>>{};
    if (tripId != null) {
      for (final day in {
        for (final node in planNodes([
          ?old,
          Record(key, kind, device, 0, deleted, data),
        ]))
          if (!node.stay) node.day,
      }) {
        orders[day] = timeline(tripId, day).map((n) => n.id).toList();
      }
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final r = Record(
      key,
      kind,
      device,
      old != null && old.modified >= now ? old.modified + 1 : now,
      deleted,
      data,
    );
    db.execute('BEGIN IMMEDIATE');
    try {
      _put(r);
      // Preserve the currently visible anchors before changing a timed record.
      for (final entry in orders.entries) {
        final orderId = 'order:$tripId:${entry.key}';
        final prior = get(orderId);
        final current = planNodes(
          items(tripId!),
        ).where((n) => n.day == entry.key && !n.stay).map((n) => n.id).toList();
        final ids = [
          ...entry.value.where(current.contains),
          ...current.where((id) => !entry.value.contains(id)),
        ];
        if (prior != null && jsonEncode(prior.data['ids']) == jsonEncode(ids)) {
          continue;
        }
        _put(
          Record(
            orderId,
            'order',
            device,
            prior != null && prior.modified >= now ? prior.modified + 1 : now,
            false,
            {'trip': tripId, 'day': entry.key, 'ids': ids},
          ),
        );
      }
      if (kind == 'trip' && old != null && old.data['start'] != data['start']) {
        for (final item in items(
          key,
        ).where((i) => i.data['booking'] != '已预订')) {
          final fields = Map<String, dynamic>.from(item.data['fields']);
          for (final end in [false, true]) {
            final field = end ? 'endDate' : 'startDate';
            if ((fields[field] ?? '') != '') {
              fields[field] = dayDate(data, item.data[end ? 'endDay' : 'day']);
            }
          }
          final before = parseDate(old.data['start']),
              after = parseDate(data['start']);
          final appointment = parseDate(fields['reservationDate'] ?? '');
          if (appointment != null && before != null && after != null) {
            fields['reservationDate'] = dateText(
              appointment.add(after.difference(before)),
            );
          }
          _put(
            Record(
              item.id,
              item.kind,
              device,
              item.modified >= now ? item.modified + 1 : now,
              false,
              {...item.data, 'fields': fields},
            ),
          );
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    generation++;
    notifyListeners();
    return r;
  }

  void remove(Record r) => save(r.kind, r.data, id: r.id, deleted: true);
  void reorder(String trip, int day, List<String> ids) => save('order', {
    'trip': trip,
    'day': day,
    'ids': ids,
  }, id: 'order:$trip:$day');
  void merge(List<Record> incoming) {
    var changed = false;
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final r in incoming) {
        final old = get(r.id);
        if (old != null && old.kind != r.kind) {
          throw const FormatException('记录类型冲突');
        }
        if (old == null || r.newerThan(old)) {
          _put(r);
          changed = true;
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    if (changed) {
      generation++;
      notifyListeners();
    }
  }

  String export({String? trip, bool sync = false}) {
    final liveTrips = trips.map((r) => r.id).toSet();
    final rows = all.where(
      (r) =>
          sync ||
          (!r.deleted &&
              (r.kind == 'trip'
                  ? liveTrips.contains(r.id)
                  : liveTrips.contains(r.data['trip']))),
    );
    return jsonEncode({
      'format': sync ? 'howdoi-sync' : 'howdoi-backup',
      'version': 2,
      'records': rows
          .where((r) => trip == null || r.id == trip || r.data['trip'] == trip)
          .map((r) => r.toJson())
          .toList(),
    });
  }

  int importCopy(List<Record> rows) {
    final trips = rows.where((r) => r.kind == 'trip' && !r.deleted).toList();
    final tripIds = trips.map((r) => r.id).toSet();
    if (rows.any(
      (r) =>
          !r.deleted && r.kind != 'trip' && !tripIds.contains(r.data['trip']),
    )) {
      throw const FormatException('备份缺少关联旅行');
    }
    final ids = {for (final r in rows) r.id: uuid.v4()};
    final imported = <Record>[];
    for (final r in rows.where((r) => !r.deleted)) {
      final d = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(r.data)) as Map,
      );
      var id = ids[r.id]!;
      if (r.kind != 'trip') d['trip'] = ids[d['trip']];
      if (r.kind == 'order' || r.kind == 'day') {
        id = '${r.kind}:${d['trip']}:${d['day']}';
      }
      if (r.kind == 'order') {
        d['ids'] = [
          for (final value in d['ids'] as List)
            if (ids.containsKey((value as String).split('@').first))
              '${ids[value.split('@').first]}${value.contains('@') ? '@${value.split('@').last}' : ''}',
        ];
      }
      if (r.kind == 'item') {
        for (final c in d['costs']) {
          c['id'] = uuid.v4();
        }
        for (final key in ['fromId', 'toId']) {
          if ((d['fields'][key] ?? '') != '') {
            d['fields'][key] = ids[d['fields'][key]] ?? '';
          }
        }
      }
      imported.add(
        Record(
          id,
          r.kind,
          device,
          DateTime.now().toUtc().microsecondsSinceEpoch,
          false,
          d,
        ),
      );
    }
    merge(imported);
    return trips.length;
  }

  @override
  void dispose() {
    db.close();
    super.dispose();
  }
}
