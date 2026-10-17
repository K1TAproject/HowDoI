import 'package:flutter/material.dart';
import 'model.dart';
import 'planner.dart';
import 'store.dart';
import 'maps.dart';

class TripOverviewData {
  final Record trip;
  late final List<Record> items;
  late final List<int> days;
  late final List<PlanNode> nodes;
  late final List<int> bounds;
  late final Map<int, List<PlanNode>> byDay;
  late final Budget budget;
  TripOverviewData(Store store, this.trip) {
    items = store.items(trip.id);
    days = store.visibleDays(trip.id);
    nodes = planNodes(items);
    bounds = {
      ...days,
      for (final r in items)
        ...[r.data['day'] as int, r.data['endDay'] as int].where((d) => d > 0),
    }.toList()..sort();
    final orders = {
      for (final r in store.all.where((r) => r.kind == 'order' && !r.deleted))
        r.id: r.data['ids'] as List,
    };
    byDay = {
      for (final day in [...days, 0])
        day: [
          ...orderedNodes(
            nodes.where((n) => n.day == day && !n.stay).toList(),
            orders['order:${trip.id}:$day'] ?? [],
            timed: day != 0,
          ),
          ...nodes.where(
            (n) =>
                n.day == day &&
                n.stay &&
                !nodes.any(
                  (x) =>
                      x.day == day &&
                      x.item.id == n.item.id &&
                      x.role == 'start',
                ),
          ),
        ],
    };
    budget = Budget(trip, items);
  }
  int get span => bounds.isEmpty ? 0 : bounds.last - bounds.first + 1;
  int get plannedDays =>
      nodes.where((n) => n.day > 0).map((n) => n.day).toSet().length;
  int get unknownCosts => items.fold(
    0,
    (n, r) =>
        n + (r.data['costs'] as List).where((c) => c['amount'] == '').length,
  );
  int get noBudgetItems =>
      items.where((r) => (r.data['costs'] as List).isEmpty).length;
  String get range => bounds.isEmpty
      ? '${trip.data['start'] == '' ? '未设置出发日期' : '出发：${trip.data['start']}'} · 尚无旅行日'
      : '${dayLabel(trip, bounds.first)} 至 ${dayLabel(trip, bounds.last)}';

  // Each row is an existing arrangement. Only its own recorded transport endpoints
  // form a connection; neighboring rows never imply transportation.
  List<String> places(PlanNode n) {
    final d = n.item.data;
    if (isTransport(d['type'])) {
      if (n.end) {
        return [
          fieldText(d, 'destination'),
        ].where((s) => s.trim().isNotEmpty).toList();
      }
      return [
        fieldText(d, 'origin'),
        if (d['type'] != '租车' &&
            (d['day'] == d['endDay'] ||
                d['endDay'] == 0 ||
                !scheduledTransport(d['type'])))
          fieldText(d, 'destination'),
      ].where((s) => s.trim().isNotEmpty).toList();
    }
    if (n.end || n.stay && n.day != d['day']) return [];
    final address = fieldText(d, 'address').trim();
    if (address.isNotEmpty) return [address];
    if (d['type'] == '住宿' && (d['name'] as String).trim().isNotEmpty) {
      return [(d['name'] as String).trim()];
    }
    return [];
  }

  List<PlanNode> route(int day) {
    final seen = <String>{};
    return (byDay[day] ?? [])
        .where(
          (n) => places(n).isNotEmpty && seen.add(n.stay ? n.item.id : n.id),
        )
        .toList();
  }

  Set<String> get placeNames => {
    for (final day in [...days, 0])
      for (final n in route(day)) ...places(n).map((s) => s.trim()),
  };
}

String overviewItemDetail(Record trip, PlanNode n) {
  final d = n.item.data;
  return [
    if (n.time.isNotEmpty) n.time,
    '${n.stay ? '当晚住宿 · ' : n.prefix}${itemType(d)}',
    if (fieldText(d, 'number').isNotEmpty) fieldText(d, 'number'),
    if (!n.end && isTransport(d['type']) && fieldText(d, 'endTime').isNotEmpty)
      '到达/结束 ${fieldText(d, 'endTime')}',
    if (d['endDay'] > d['day'] && d['day'] > 0)
      '${dayLabel(trip, d['day'])} → ${dayLabel(trip, d['endDay'])}${d['type'] == '住宿' ? ' · ${d['endDay'] - d['day']} 晚，末日退房' : ''}',
    if (dateWarning(trip, d).isNotEmpty) '票面日期与安排不一致，请核对',
  ].join(' · ');
}

class TripOverview extends StatelessWidget {
  final Store store;
  final Record trip;
  final ValueChanged<int> onDay;
  final ValueChanged<Record> onItem;
  const TripOverview({
    super.key,
    required this.store,
    required this.trip,
    required this.onDay,
    required this.onItem,
  });

  @override
  Widget build(BuildContext context) {
    final data = TripOverviewData(store, trip);
    final prep = store.preparations(trip);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    );
    Widget item(PlanNode n) => ListTile(
      title: Text(itemTitle(n.item.data)),
      subtitle: Text(overviewItemDetail(trip, n)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => onItem(n.item),
    );
    final currenciesPresent = currencies.where(
      (c) => data.items.any(
        (r) => (r.data['costs'] as List).any((v) => v['currency'] == c),
      ),
    );
    return ListView(
      key: PageStorageKey('overview:${trip.id}'),
      padding: const EdgeInsets.all(20),
      children: [
        Text('旅行总览', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(trip.data['name'], style: Theme.of(context).textTheme.titleLarge),
        Text(data.range),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            Text('旅行跨度 ${data.span} 天'),
            Text('已有旅行日 ${data.days.length} 天'),
            Text('有行程 ${data.plannedDays} 天'),
            Text('行程 ${data.items.length} 条'),
            Text(
              '准备 ${prep.where((p) => p['done'] == true).length}/${prep.length}',
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '跨度包含首末安排日之间的空缺及已记录退房/结束日，不补建日期；有行程天数按每日可见行程计算，含住宿覆盖与跨日抵达。行程数量按原始记录计数，包含历史未安排记录。',
          style: TextStyle(fontSize: 12),
        ),
        heading('按天行程'),
        if (data.days.isEmpty) const Text('尚无旅行日，可从左侧添加日期。'),
        for (final day in data.days)
          Card(
            child: ExpansionTile(
              key: PageStorageKey('overview-day:${trip.id}:$day'),
              initiallyExpanded: data.days.length <= 7,
              title: TextButton(
                style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                onPressed: () => onDay(day),
                child: Text(dayTitle(trip, day)),
              ),
              subtitle: Text(
                '${daySubtitle(trip, day)}${daySubtitle(trip, day).isEmpty ? '' : ' · '}${data.byDay[day]!.map((n) => n.item.id).toSet().length} 条关联行程',
              ),
              children: [
                if (data.byDay[day]!.isEmpty)
                  const ListTile(title: Text('主动保留的空白日期')),
                for (final n in data.byDay[day]!) item(n),
              ],
            ),
          ),
        if (data.items.any((r) => r.data['day'] == 0))
          Card(
            child: ExpansionTile(
              key: PageStorageKey('overview-history:${trip.id}'),
              title: const Text('历史未安排日期的行程'),
              subtitle: const Text('未纳入日期顺序，预算仍计入总计'),
              children: [
                for (final r in data.items.where((r) => r.data['day'] == 0))
                  item(PlanNode(r, 0)),
              ],
            ),
          ),
        heading('旅行地图'),
        ExpansionTile(
          key: PageStorageKey('overview-map:${trip.id}'),
          title: const Text('查看旅行地图'),
          children: [
            TripMap(
              nodes: [
                for (final day in [...data.days, 0]) ...data.byDay[day]!,
              ],
              onItem: onItem,
            ),
          ],
        ),
        heading('地点与到访顺序'),
        const Text(
          '按现有行程顺序列出；行与行之间仅表示先后，不代表交通连接。跨日交通在出发日列起点、到达日列终点；住宿覆盖日不重复推定到访。',
          style: TextStyle(fontSize: 12),
        ),
        if (data.placeNames.isEmpty) const ListTile(title: Text('尚无明确记录的地点')),
        if (data.placeNames.isNotEmpty)
          ExpansionTile(
            key: PageStorageKey('overview-places:${trip.id}'),
            title: Text('地点清单 · ${data.placeNames.length} 个名称'),
            subtitle: const Text('包含历史未安排记录；仅合并首尾空白处理后完全相同的名称'),
            children: [
              for (final name in data.placeNames) ListTile(title: Text(name)),
            ],
          ),
        for (final day in data.days.where((d) => data.route(d).isNotEmpty)) ...[
          Text(
            dayLabel(trip, day),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final n in data.route(day))
            ListTile(
              title: Text(
                isTransport(n.item.data['type']) &&
                        n.item.data['type'] != '租车' &&
                        !n.end &&
                        n.item.data['day'] == n.item.data['endDay'] &&
                        data.places(n).length == 2
                    ? data.places(n).join(' → ')
                    : data.places(n).join(' · '),
              ),
              subtitle: Text(
                '${n.item.data['type'] == '租车'
                    ? '取还车安排'
                    : isTransport(n.item.data['type'])
                    ? '已记录${n.end ? '抵达' : '交通'}'
                    : '行程位置'} · ${overviewItemDetail(trip, n)}',
              ),
              onTap: () => onItem(n.item),
              trailing: const Icon(Icons.chevron_right),
            ),
        ],
        if (data.items.any((r) => r.data['day'] == 0))
          const Text('历史未安排记录的地点不插入到访顺序，可在上方记录中查看。'),
        heading('预计预算 · 原币种'),
        Text('未估算费用 ${data.unknownCosts} 笔 · ${data.noBudgetItems} 条行程未填写预算'),
        if (currenciesPresent.isEmpty) const ListTile(title: Text('暂无预算条目')),
        for (final currency in currenciesPresent)
          budgetCurrency(context, data, currency),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget budgetCurrency(
    BuildContext context,
    TripOverviewData data,
    String currency,
  ) {
    final total = data.budget.byCurrency[currency];
    final entries = [
      for (final r in data.items)
        for (final c in r.data['costs'])
          if (c['currency'] == currency) (item: r, cost: c as Map),
    ];
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('overview-currency:${trip.id}:$currency'),
        initiallyExpanded: true,
        title: Text(
          '$currency ${total == null ? '预算未估算' : formatUnits(total, digits(currency))}',
        ),
        subtitle: Text(
          '${entries.where((e) => e.cost['amount'] == '').length} 笔未估算${total == null
              ? ' · 全部未估算，无占比'
              : total == BigInt.zero
              ? ' · 总额为零，无占比'
              : ''}',
        ),
        children: [
          for (final category in categories.where(
            (c) => entries.any((e) => e.cost['category'] == c),
          ))
            Builder(
              builder: (context) {
                final costs = entries
                    .where((e) => e.cost['category'] == category)
                    .toList();
                final subtotal = data.budget.byCategory[category]?[currency];
                final share =
                    total != null && total > BigInt.zero && subtotal != null
                    ? ((subtotal * BigInt.from(1000) + total ~/ BigInt.two) ~/
                                  total)
                              .toInt() /
                          10
                    : null;
                return ExpansionTile(
                  key: PageStorageKey(
                    'overview-category:${trip.id}:$currency:$category',
                  ),
                  title: Text(
                    '$category · ${subtotal == null ? '未估算' : '$currency ${formatUnits(subtotal, digits(currency))}'}${share == null ? '' : ' · ${share.toStringAsFixed(1)}%'}',
                  ),
                  subtitle: Text(
                    '${costs.length} 笔费用 · ${costs.where((e) => e.cost['amount'] == '').length} 笔未估算',
                  ),
                  children: [
                    for (final entry in costs)
                      ListTile(
                        title: Text(
                          '${entry.cost['label'] == '' ? '未命名费用' : entry.cost['label']} · $currency ${entry.cost['amount'] == '' ? '未估算' : formatUnits(decimalUnits(entry.cost['amount'], digits(currency)), digits(currency))}',
                        ),
                        subtitle: Text(
                          '${itemTitle(entry.item.data)} · ${entry.item.data['day'] == 0 ? '历史未安排日期' : dayLabel(trip, entry.item.data['day'])}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => onItem(entry.item),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
