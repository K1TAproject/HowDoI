import 'places.dart';
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
  Map<int, List<PlanNode>> get summaryByDay {
    final seen = <String>{};
    return {
      for (final day in [...days, 0])
        day: [
          for (final n in byDay[day] ?? <PlanNode>[])
            if (seen.add(n.item.id)) n,
        ],
    };
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
    if (multiPlace(d)) {
      return activityPlaces(d)
          .map((p) => p['name'] as String)
          .where((n) => n.trim().isNotEmpty)
          .toList();
    }
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
    itemType(d),
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
  final VoidCallback? onPreparations;
  const TripOverview({
    super.key,
    required this.store,
    required this.trip,
    required this.onDay,
    required this.onItem,
    this.onPreparations,
  });

  @override
  Widget build(BuildContext context) {
    final data = TripOverviewData(store, trip);
    final prep = store.preparations(trip);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    );
    Widget item(PlanNode n) {
      final d = n.item.data;
      final slots = placeSlots(d).where((slot) => hasPlace(d, slot)).toList();
      String label(String slot) {
        final text = multiPlace(d) || isTransport(d['type'])
            ? placeText(d, slot)
            : (d['name'] as String).trim();
        return text.isNotEmpty
            ? text
            : locationBinding(d, slot)?['name'] ?? itemTitle(d);
      }

      final title = itemTitle(d);
      final showTitle =
          slots.isEmpty ||
          multiPlace(d) && !(slots.length == 1 && label(slots.single) == title);
      Widget place(String slot) {
        final binding = locationBinding(d, slot);
        final stale = placeStale(d, slot);
        final prefix = binding?['url'] != null
            ? ''
            : linkedPlace(d, slot) != null && !stale
            ? '导航 · '
            : '搜索地点 · ';
        return TextButton(
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            minimumSize: const Size(48, 48),
            textStyle: Theme.of(context).textTheme.titleMedium,
          ),
          onPressed: () => navigatePlace(context, store, d, slot: slot),
          child: Text('$prefix${label(slot)}${stale ? ' · ⚠ 请核对绑定地点' : ''}'),
        );
      }

      return Padding(
        key: ValueKey('summary:${n.item.id}'),
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showTitle)
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                  if (isTransport(d['type']))
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (var i = 0; i < slots.length; i++) ...[
                          if (i > 0) const Text('→'),
                          place(slots[i]),
                        ],
                      ],
                    )
                  else
                    for (final slot in slots) place(slot),
                  Text(
                    overviewItemDetail(trip, n),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '编辑行程',
              onPressed: () => onItem(n.item),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      );
    }

    final summary = data.summaryByDay;
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
            TextButton(
              onPressed: onPreparations,
              child: Text(
                '准备 ${prep.where((p) => p['done'] == true).length}/${prep.length}',
              ),
            ),
          ],
        ),
        heading('行程动向'),
        if (data.days.isEmpty) const Text('尚无旅行日，可从左侧添加日期。'),
        for (final day in data.days) ...[
          TextButton(
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => onDay(day),
            child: Text(dayTitle(trip, day)),
          ),
          if (daySubtitle(trip, day).isNotEmpty)
            Text(
              daySubtitle(trip, day),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          for (final n in summary[day]!) item(n),
          if (summary[day]!.isEmpty)
            Text(
              data.byDay[day]!.isEmpty ? '暂无行程' : '住宿覆盖或跨日到达，详情见前述行程',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
        if (summary[0]!.isNotEmpty) ...[
          heading('历史未安排日期的行程'),
          const Text('未纳入日期顺序，预算仍计入总计'),
          for (final n in summary[0]!) item(n),
        ],
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
        initiallyExpanded: false,
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
                          '${itemTitle(entry.item.data)} · $currency ${entry.cost['amount'] == '' ? '未估算' : formatUnits(decimalUnits(entry.cost['amount'], digits(currency)), digits(currency))}',
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
