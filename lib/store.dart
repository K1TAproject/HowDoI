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
    if (setting('dataVersion') != '3') {
      if (path != ':memory:' &&
          db.select('SELECT id FROM records LIMIT 1').isNotEmpty) {
        final backup =
            '$path.pre-0.1.2-${DateTime.now().microsecondsSinceEpoch}.db';
        db.execute('VACUUM INTO ?', [backup]);
        setSetting('upgradeBackup', backup);
      }
      setSetting('dataVersion', '3');
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
  List<int> visibleDays(String trip) => ({
    ...planNodes(items(trip)).map((n) => n.day).where((d) => d > 0),
    ...all
        .where(
          (r) =>
              r.kind == 'day' &&
              !r.deleted &&
              r.data['trip'] == trip &&
              r.data['explicit'] == true,
        )
        .map((r) => r.data['day'] as int),
  }.toList()..sort());

  List<Map<String, dynamic>> preparations(Record trip) => [
    for (final p in trip.data['preparations'] as List? ?? [])
      Map<String, dynamic>.from(p),
  ];

  void savePreparations(Record trip, List<Map<String, dynamic>> entries) {
    final current = get(trip.id);
    if (current == null ||
        current.deleted ||
        current.modified != trip.modified) {
      throw const FormatException('旅行或准备清单已改变，请重新打开后编辑');
    }
    save('trip', {...current.data, 'preparations': entries}, id: trip.id);
  }

  int addDay(Record trip) {
    final day = (visibleDays(trip.id).lastOrNull ?? 0) + 1;
    save('day', {
      'trip': trip.id,
      'day': day,
      'zone': trip.data['zone'],
      'explicit': true,
    }, id: 'day:${trip.id}:$day');
    return day;
  }

  void assignDay(Record item, int day, {int? endDay}) {
    final latest = get(item.id);
    if (latest == null || latest.deleted || latest.modified != item.modified) {
      throw const FormatException('记录已改变，请重新打开');
    }
    final data = {...latest.data, 'day': day};
    if (endDay != null) data['endDay'] = endDay;
    if (data['endDay'] == 0 && data['type'] != '住宿') data['endDay'] = day;
    save('item', data, id: item.id);
  }

  List<Record> primaryItems(String trip, int day) =>
      items(trip).where((r) => r.data['day'] == day).toList();

  List<Record> relatedItems(String trip, int day) => {
    for (final n in planNodes(items(trip)))
      if (n.day == day && n.item.data['day'] != day) n.item.id: n.item,
  }.values.toList();

  // Validate the whole operation before a single transaction. The preview is
  // invalidated by any intervening local edit or sync.
  void changeDay(
    Record trip,
    int source, {
    int? target,
    bool deleteItems = false,
    bool requireSourceRemoved = false,
    required int expectedGeneration,
  }) {
    if (generation != expectedGeneration || get(trip.id)?.deleted != false) {
      throw const FormatException('数据已改变，请重新预览日期操作');
    }
    if (source < 1 ||
        target == source ||
        target != null && (target < 1 || target > 3660)) {
      throw const FormatException('请选择不同的有效旅行日');
    }
    final primary = primaryItems(trip.id, source);
    final related = relatedItems(trip.id, source);
    if ((target == null || requireSourceRemoved) && related.isNotEmpty) {
      throw const FormatException('此日期仍有住宿覆盖或跨日关联，请先调整原行程日期');
    }
    if (primary.isNotEmpty && target == null && !deleteItems) {
      throw const FormatException('请先选择行程移往的日期');
    }
    final changes = <Record>[];
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    Record updated(
      String id,
      String kind,
      Map<String, dynamic> data, {
      bool deleted = false,
    }) {
      validateData(kind, data);
      final old = get(id);
      return Record(
        id,
        kind,
        device,
        old != null && old.modified >= now ? old.modified + 1 : now,
        deleted,
        data,
      );
    }

    for (final r in primary) {
      if (deleteItems) {
        changes.add(updated(r.id, r.kind, r.data, deleted: true));
        continue;
      }
      final delta = target! - source;
      final end = r.data['endDay'] as int;
      final data = {
        ...r.data,
        'day': target,
        'endDay': end == 0 ? 0 : end + delta,
      };
      final fields = Map<String, dynamic>.from(r.data['fields']);
      if (r.data['booking'] != '已预订') {
        for (final entry in {'startDate': 'day', 'endDate': 'endDay'}.entries) {
          if ((fields[entry.key] ?? '') != '') {
            fields[entry.key] = dayDate(trip.data, data[entry.value]);
          }
        }
        final reservation = parseDate(fields['reservationDate'] ?? '');
        if (reservation != null) {
          fields['reservationDate'] = dateText(
            DateTime(
              reservation.year,
              reservation.month,
              reservation.day + delta,
            ),
          );
        }
      }
      data['fields'] = fields;
      changes.add(updated(r.id, r.kind, data));
    }
    Map<String, dynamic> dayData(int value) => {
      ...?get('day:${trip.id}:$value')?.data,
      'trip': trip.id,
      'day': value,
      'zone': trip.data['zone'],
      'explicit': true,
    };
    changes.add(
      updated('day:${trip.id}:$source', 'day', dayData(source), deleted: true),
    );
    if (target != null) {
      changes.add(updated('day:${trip.id}:$target', 'day', dayData(target)));
    }
    final replacements = {
      for (final r in changes.where((r) => r.kind == 'item')) r.id: r,
    };
    final after = items(
      trip.id,
    ).map((r) => replacements[r.id] ?? r).where((r) => !r.deleted).toList();
    final beforeNodes = planNodes(items(trip.id)),
        afterNodes = planNodes(after);
    if (requireSourceRemoved && afterNodes.any((n) => n.day == source)) {
      throw const FormatException('移动后的住宿或跨日记录仍覆盖原日期，请选择其他目标日或先调整原行程');
    }
    for (final d in {
      ...beforeNodes
          .where((n) => replacements.containsKey(n.item.id))
          .map((n) => n.day),
      ...afterNodes
          .where((n) => replacements.containsKey(n.item.id))
          .map((n) => n.day),
      source,
      ?target,
    }) {
      final current = afterNodes
          .where((n) => n.day == d && !n.stay)
          .map((n) => n.id)
          .toList();
      final prior = timeline(trip.id, d).map((n) => n.id).toList();
      // Existing target anchors first, then moved source anchors; timed groups
      // continue to use orderedNodes when displayed.
      final incoming = beforeNodes
          .where((n) => n.day != d && current.contains(n.id))
          .map((n) => n.day)
          .toSet();
      final preferred = [
        ...prior,
        for (final oldDay in incoming)
          ...timeline(trip.id, oldDay).map((n) => n.id),
      ];
      final ids = {...preferred.where(current.contains), ...current}.toList();
      if (listEquals(get('order:${trip.id}:$d')?.data['ids'] as List?, ids)) {
        continue;
      }
      changes.add(
        updated('order:${trip.id}:$d', 'order', {
          'trip': trip.id,
          'day': d,
          'ids': ids,
        }),
      );
    }
    merge(changes);
  }

  void undoEmptyDay(Record deletedDay) {
    final current = get(deletedDay.id);
    if (current == null ||
        !current.deleted ||
        current.modified != deletedDay.modified) {
      throw const FormatException('此日期已再次改变，无法撤销');
    }
    if (get(deletedDay.data['trip'])?.deleted != false) {
      throw const FormatException('旅行已删除');
    }
    save('day', deletedDay.data, id: deletedDay.id);
  }

  void snapshot(String target) => db.execute('VACUUM INTO ?', [target]);
  void restoreSnapshot(String source) {
    db.execute('ATTACH DATABASE ? AS update_backup', [source]);
    try {
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('DELETE FROM records');
        db.execute('INSERT INTO records SELECT * FROM update_backup.records');
        db.execute('DELETE FROM settings');
        db.execute('INSERT INTO settings SELECT * FROM update_backup.settings');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.execute('DETACH DATABASE update_backup');
    }
    generation++;
    notifyListeners();
  }

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
      if (rows.any(
        (r) =>
            r.kind == 'item' &&
            (r.data['locations'] as Map?)?.isNotEmpty == true,
      ))
        'mapAttribution':
            '© OpenStreetMap contributors, ODbL; https://www.openstreetmap.org/copyright',
      'version': 4,
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
