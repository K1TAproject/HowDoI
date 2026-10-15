import 'model.dart';

String itemType(Map<String, dynamic> d) => switch (d['type']) {
  '游览' => '游览/活动',
  '市内交通' || '自驾' || '出租车' => '交通/移动',
  _ => d['type'] as String,
};
const editorTypes = [
  '游览/活动',
  '餐饮',
  '购物',
  '其他',
  '住宿',
  '航班',
  '铁路',
  '交通/移动',
  '长途汽车',
  '轮渡',
  '租车',
];
bool isTransport(String type) => [
  '航班',
  '铁路',
  '交通/移动',
  '市内交通',
  '自驾',
  '出租车',
  '长途汽车',
  '轮渡',
  '租车',
].contains(type);
bool scheduledTransport(String type) =>
    ['航班', '铁路', '长途汽车', '轮渡'].contains(type);
String fieldText(Map<String, dynamic> d, String key) =>
    (d['fields'] as Map)[key] as String? ?? '';
String itemTitle(Map<String, dynamic> d) {
  if (isTransport(d['type'])) {
    final from = fieldText(d, 'origin'), to = fieldText(d, 'destination');
    if (from.isNotEmpty || to.isNotEmpty) {
      return '${from.isEmpty ? '出发地待定' : from} → ${to.isEmpty ? '目的地待定' : to}';
    }
  }
  if ((d['name'] as String).trim().isNotEmpty) return d['name'];
  return fieldText(d, 'number').isNotEmpty
      ? fieldText(d, 'number')
      : itemType(d);
}

String itemDate(Record trip, Map<String, dynamic> d, bool end) {
  final fixed = fieldText(d, end ? 'endDate' : 'startDate');
  return fixed.isNotEmpty
      ? fixed
      : dayDate(trip.data, d[end ? 'endDay' : 'day']);
}

String dayLabel(Record trip, int day) => day == 0
    ? '待安排'
    : '${dayDate(trip.data, day).isEmpty ? '' : '${dayDate(trip.data, day)} · '}第 $day 天';
String dayTitle(Record trip, int day) {
  final date = parseDate(dayDate(trip.data, day));
  return date == null
      ? '第 $day 天'
      : '${date.month}月${date.day}日 · 周${'一二三四五六日'[date.weekday - 1]}';
}

String daySubtitle(Record trip, int day) {
  final date = parseDate(dayDate(trip.data, day));
  return date == null ? '' : '第 $day 天 · ${date.year}年';
}

String durationText(String value) {
  final minutes = int.tryParse(value);
  if (minutes == null) return value;
  return '${minutes >= 60 ? '${minutes ~/ 60}小时' : ''}${minutes % 60 != 0 || minutes == 0 ? '${minutes % 60}分钟' : ''}';
}

String itemBudgetText(Record trip, Record item, {bool whole = false}) {
  if ((item.data['costs'] as List).isEmpty) return '';
  final budget = Budget(trip, [item]);
  if (budget.byCurrency.isEmpty) return whole ? '整条行程预算未估算' : '预算未估算';
  final values = [
    for (final c in currencies.where(budget.byCurrency.containsKey))
      '$c ${formatUnits(budget.byCurrency[c]!, digits(c))}',
  ];
  return '${whole ? '整条行程预算' : '预计'}：${values.join(' · ')}${budget.unknown > 0 ? ' · 含未估算' : ''}';
}

String dateWarning(Record trip, Map<String, dynamic> d) {
  final warnings = <String>[];
  for (final end in [false, true]) {
    final fixed = fieldText(d, end ? 'endDate' : 'startDate');
    final planned = dayDate(trip.data, d[end ? 'endDay' : 'day']);
    if (fixed.isNotEmpty && planned.isNotEmpty && fixed != planned) {
      warnings.add('${end ? '结束' : '开始'}固定日期 $fixed 与旅行日 $planned 不同，请确认');
    }
  }
  return warnings.join('\n');
}

class PlanNode {
  final Record item;
  final int day;
  final String role;
  PlanNode(this.item, this.day, [this.role = 'start']);
  String get id => role == 'start' ? item.id : '${item.id}@$role';
  bool get end => role == 'end';
  bool get stay => role == 'stay';
  String get time {
    if (stay) return '';
    final d = item.data;
    final value = fieldText(d, end ? 'endTime' : 'startTime');
    return value.isNotEmpty || end ? value : fieldText(d, 'reservationTime');
  }

  bool get appointment =>
      !end &&
      !stay &&
      fieldText(item.data, 'startTime').isEmpty &&
      fieldText(item.data, 'reservationTime').isNotEmpty;
  String get prefix => stay
      ? ''
      : itemType(item.data) == '住宿'
      ? (end ? '退房 · ' : '入住 · ')
      : itemType(item.data) == '租车'
      ? (end ? '还车 · ' : '取车 · ')
      : end
      ? '抵达 · '
      : '';
}

List<PlanNode> planNodes(Iterable<Record> items) {
  final nodes = <PlanNode>[];
  for (final item in items) {
    final d = item.data, type = itemType(d);
    final start = d['day'] as int, end = d['endDay'] as int;
    if (type == '住宿' && start > 0) {
      // A partial stay still has a visible draft on its known check-in day.
      for (var day = start; day < (end > start ? end : start + 1); day++) {
        nodes.add(PlanNode(item, day, 'stay'));
      }
      if (fieldText(d, 'startTime').isNotEmpty) {
        nodes.add(PlanNode(item, start));
      }
      if (end > 0 && fieldText(d, 'endTime').isNotEmpty) {
        nodes.add(PlanNode(item, end, 'end'));
      }
    } else {
      nodes.add(PlanNode(item, start));
      if (end > 0 &&
          ((scheduledTransport(type) && start != end) || type == '租车')) {
        nodes.add(PlanNode(item, end, 'end'));
      }
    }
  }
  return nodes;
}

List<PlanNode> orderedNodes(
  List<PlanNode> rows,
  List ids, {
  bool timed = true,
}) {
  final positions = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  rows.sort((a, b) {
    final x = positions[a.id], y = positions[b.id];
    if (x != null || y != null) {
      return (x ?? ids.length).compareTo(y ?? ids.length);
    }
    final result = a.item.modified.compareTo(b.item.modified);
    return result != 0 ? result : a.id.compareTo(b.id);
  });
  if (!timed) return rows;
  final leading = <PlanNode>[];
  final groups = <List<PlanNode>>[];
  for (final node in rows) {
    if (node.time.isNotEmpty) {
      groups.add([node]);
    } else {
      (groups.isEmpty ? leading : groups.last).add(node);
    }
  }
  final original = {
    for (var i = 0; i < groups.length; i++) groups[i].first.id: i,
  };
  groups.sort((a, b) {
    final t = a.first.time.compareTo(b.first.time);
    return t != 0 ? t : original[a.first.id]!.compareTo(original[b.first.id]!);
  });
  return [...leading, for (final group in groups) ...group];
}
