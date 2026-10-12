import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'model.dart';
import 'store.dart';
import 'editors.dart';
import 'sync.dart';

class Home extends StatefulWidget {
  final Store store;
  final SyncService sync;
  const Home({super.key, required this.store, required this.sync});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  String? tripId, editId;
  int day = 1;
  bool editing = false;
  Store get store => widget.store;
  @override
  void initState() {
    super.initState();
    tripId = store.setting('selectedTrip');
    day = int.tryParse(store.setting('selectedDay') ?? '1') ?? 1;
    store.addListener(changed);
    widget.sync.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    store.removeListener(changed);
    widget.sync.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.sync.active = state == AppLifecycleState.resumed;
    if (widget.sync.active) widget.sync.tick();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void selectDay(int value) {
    setState(() {
      day = value;
      editing = false;
    });
    store.setSetting('selectedDay', '$day');
  }

  void selectTrip(Record trip) {
    setState(() {
      tripId = trip.id;
      editing = false;
      final start = parseDate(trip.data['start']);
      final now = DateTime.now();
      final offset = start == null
          ? -1
          : DateTime(now.year, now.month, now.day).difference(start).inDays;
      day = offset >= 0 && offset < trip.data['days'] ? offset + 1 : 1;
    });
    store.setSetting('selectedTrip', trip.id);
    store.setSetting('selectedDay', '$day');
  }

  Future<void> backup(Record? trip) async {
    try {
      final bytes = utf8.encode(store.export(trip: trip?.id));
      final result = await FilePicker.platform.saveFile(
        dialogTitle: '导出路书备份',
        fileName: 'HowDoI-${dateText(DateTime.now())}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (result != null && mounted) notice(context, '备份已导出');
    } catch (e) {
      if (mounted) notice(context, '导出失败：$e');
    }
  }

  Future<void> importBackup() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked == null) return;
      final file = File(picked.files.single.path!);
      if (await file.length() > 20 * 1024 * 1024) {
        throw const FormatException('文件超过 20 MB');
      }
      final rows = decodeRecords(await file.readAsString());
      final count = rows.where((r) => r.kind == 'trip' && !r.deleted).length;
      if (mounted &&
          await confirm(
            context,
            '导入 $count 次旅行',
            '将创建独立副本，不覆盖现有旅行，也不导入设备配对信息。',
          )) {
        final n = store.importCopy(rows);
        if (mounted) notice(context, '已导入 $n 次旅行');
      }
    } catch (e) {
      if (mounted) notice(context, '未导入：$e');
    }
  }

  void openEditor(Record trip, Record? item, bool wide) {
    if (wide) {
      setState(() {
        editId = item?.id;
        editing = true;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (c) => Scaffold(
            body: SafeArea(
              child: ItemEditor(
                store: store,
                trip: trip,
                day: day,
                item: item,
                onClose: () => Navigator.pop(c),
              ),
            ),
          ),
        ),
      );
    }
  }

  void showBudget(Record trip) {
    final b = Budget(trip, store.items(trip.id));
    final currency = trip.data['base'];
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('旅行预算'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${b.pending.isEmpty ? '预计总额' : '已折算部分'}：${formatUnits(b.total, digits(currency))} $currency',
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                for (final category in categories)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(category),
                    trailing: Text(
                      '${formatUnits(b.byCategory[category] ?? BigInt.zero, digits(currency))} $currency',
                    ),
                  ),
                if (b.pending.isNotEmpty) ...[
                  const Divider(),
                  const Text('待折算（请在旅行设置填写汇率）'),
                  for (final e in b.pending.entries)
                    Text('${e.key} ${formatUnits(e.value, digits(e.key))}'),
                ],
                Text('未估算：${b.unknown} 项'),
                const SizedBox(height: 8),
                const Text('包含待安排活动；住宿只计算一次。此处仅为预算，不是实际账本。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget navigation(Record? trip) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('我的旅行', style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final t in store.trips)
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            selected: t.id == trip?.id,
            leading: const Icon(Icons.luggage_outlined),
            title: Text(t.data['name']),
            subtitle: Text(
              '${t.data['days']} 天 · ${t.data['start'] == '' ? '日期待定' : t.data['start']}',
            ),
            onTap: () => selectTrip(t),
          ),
        OutlinedButton.icon(
          onPressed: () => editTrip(context, store),
          icon: const Icon(Icons.add),
          label: const Text('创建旅行'),
        ),
        if (trip != null) ...[
          const Divider(),
          ListTile(
            selected: day == 0,
            leading: const Icon(Icons.bookmark_border),
            title: const Text('待安排'),
            onTap: () => selectDay(0),
          ),
          for (var i = 1; i <= trip.data['days']; i++)
            ListTile(
              selected: day == i,
              title: Text('第 $i 天'),
              subtitle: dayDate(trip.data, i).isEmpty
                  ? null
                  : Text(dayDate(trip.data, i)),
              onTap: () => selectDay(i),
            ),
        ],
      ],
    );
  }

  String linkWarning(Record r, Record trip) {
    if (!isTransport(r.data['type'])) return '';
    final f = r.data['fields'] as Map;
    final from = f['fromId'] ?? '', to = f['toId'] ?? '';
    if (from == '' && to == '') return '';
    final rows = store.dayItems(trip.id, r.data['day']);
    final ids = rows.map((r) => r.id).toList();
    final index = ids.indexOf(r.id),
        left = ids.indexOf(from),
        right = ids.indexOf(to);
    if (from != '' && (left < 0 || left >= index) ||
        to != '' && (right < 0 || right <= index)) {
      return '地点顺序或日期已改变，交通待确认';
    }
    final places = rows
        .where((v) => !isTransport(v.data['type']))
        .map((v) => v.id)
        .toList();
    if (from != '' &&
        to != '' &&
        places.indexOf(to) != places.indexOf(from) + 1) {
      return '前后地点已改变，交通待确认';
    }
    return '';
  }

  Widget itemCard(Record r, Record trip, bool wide) {
    final d = r.data, f = d['fields'] as Map;
    final warning = linkWarning(r, trip);
    final timing = timeSummary(
      trip,
      d,
      store.zone(trip, d['day']),
      endZone: store.zone(trip, d['endDay']),
    );
    return Card(
      key: ValueKey(r.id),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: Checkbox(
          value: d['done'],
          onChanged: (v) {
            try {
              store.save('item', {...d, 'done': v}, id: r.id);
            } catch (e) {
              notice(context, e);
            }
          },
        ),
        title: Text(
          d['name'],
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: d['done'] ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${d['type']} · ${f['startTime'] == null || f['startTime'] == '' ? '时间待定' : f['startTime']} · ${d['booking']}',
            ),
            if (d['type'] == '住宿')
              Text('第 ${d['day']} 天入住 → 第 ${d['endDay']} 天退房'),
            if ((f['address'] ?? '') != '')
              Text(f['address'], maxLines: 1, overflow: TextOverflow.ellipsis),
            if (warning.isNotEmpty)
              Text(
                warning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (timing.isNotEmpty)
              Text(
                timing,
                style: TextStyle(
                  color: timing.contains('请')
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                maxLines: 3,
              ),
          ],
        ),
        onTap: () => openEditor(trip, r, wide),
        trailing: const Padding(
          padding: EdgeInsets.only(right: 24),
          child: Icon(Icons.chevron_right),
        ),
      ),
    );
  }

  Widget itinerary(Record trip, bool wide) {
    final rows = store.dayItems(trip.id, day);
    final stays = store
        .items(trip.id)
        .where(
          (r) =>
              r.data['type'] == '住宿' &&
              r.data['day'] > 0 &&
              r.data['day'] < day &&
              r.data['endDay'] >= day,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                day == 0 ? '留给下一段旅程' : '第 $day 天',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              Text(
                day == 0
                    ? '收集想去的地方，确定后再安排日期。'
                    : dayDate(trip.data, day).isEmpty
                    ? '日期未定，按自己的节奏编排。'
                    : dayDate(trip.data, day),
              ),
              if (day > 0)
                TextButton.icon(
                  onPressed: () async {
                    final v = await pickZone(context, store.zone(trip, day));
                    if (v != null) {
                      store.save('day', {
                        'trip': trip.id,
                        'day': day,
                        'zone': v,
                      }, id: 'day:${trip.id}:$day');
                    }
                  },
                  icon: const Icon(Icons.public, size: 16),
                  label: Text(store.zone(trip, day)),
                ),
            ],
          ),
        ),
        for (final r in stays)
          ListTile(
            leading: const Icon(Icons.hotel_outlined),
            title: Text(
              '${r.data['name']} · ${r.data['endDay'] == day ? '今天退房' : '继续入住'}',
            ),
            subtitle: const Text('多晚住宿 · 费用只计一次'),
            onTap: () => openEditor(trip, r, wide),
          ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.route_outlined,
                        size: 56,
                        color: Colors.blueGrey,
                      ),
                      const SizedBox(height: 12),
                      const Text('还没有安排，添加第一站吧。'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => openEditor(trip, null, wide),
                        icon: const Icon(Icons.add),
                        label: const Text('添加行程'),
                      ),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  itemCount: rows.length,
                  buildDefaultDragHandles: wide,
                  padding: const EdgeInsets.only(bottom: 88),
                  itemBuilder: (c, i) => wide
                      ? itemCard(rows[i], trip, wide)
                      : ReorderableDelayedDragStartListener(
                          key: ValueKey(rows[i].id),
                          index: i,
                          child: itemCard(rows[i], trip, wide),
                        ),
                  onReorderItem: (a, b) {
                    final ids = rows.map((r) => r.id).toList();
                    ids.insert(b, ids.removeAt(a));
                    store.reorder(trip.id, day, ids);
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final trips = store.trips;
    final trip =
        trips.where((r) => r.id == tripId).firstOrNull ?? trips.firstOrNull;
    if (trip != null && day > trip.data['days']) day = 1;
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 1100;
        return Scaffold(
          appBar: AppBar(
            title: Text(trip?.data['name'] ?? 'HowDoI'),
            actions: [
              IconButton(
                tooltip: '设备同步',
                onPressed: () => showSyncDialog(context, widget.sync),
                icon: const Icon(Icons.sync),
              ),
              if (trip != null) ...[
                IconButton(
                  tooltip: '预算',
                  onPressed: () => showBudget(trip),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                ),
                IconButton(
                  tooltip: '旅行设置',
                  onPressed: () => editTrip(context, store, trip),
                  icon: const Icon(Icons.tune),
                ),
              ],
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'export':
                      await backup(trip);
                    case 'all':
                      await backup(null);
                    case 'import':
                      await importBackup();
                    case 'delete':
                      if (trip != null &&
                          await confirm(
                            context,
                            '删除旅行',
                            '整趟旅行将被删除并同步。建议先导出备份。',
                          )) {
                        store.remove(trip);
                        setState(() => editing = false);
                      }
                  }
                },
                itemBuilder: (c) => [
                  if (trip != null)
                    const PopupMenuItem(value: 'export', child: Text('导出本次旅行')),
                  const PopupMenuItem(value: 'all', child: Text('导出全部旅行')),
                  const PopupMenuItem(value: 'import', child: Text('导入备份副本')),
                  if (trip != null)
                    const PopupMenuItem(value: 'delete', child: Text('删除本次旅行')),
                ],
              ),
            ],
          ),
          drawer: wide
              ? null
              : Drawer(child: SafeArea(child: navigation(trip))),
          body: Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: InkWell(
                  onTap: () => showSyncDialog(context, widget.sync),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.sync.enabled
                              ? Icons.wifi
                              : Icons.offline_bolt_outlined,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.sync.status,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const Text('本地自动保存', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    if (wide) ...[
                      SizedBox(width: 230, child: navigation(trip)),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      child: trip == null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.explore_outlined,
                                    size: 72,
                                    color: Colors.blueGrey,
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    '每段旅程，从这里开始',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineSmall,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text('离线路书 · 自由编排 · 预算心中有数'),
                                  const SizedBox(height: 24),
                                  FilledButton.icon(
                                    onPressed: () => editTrip(context, store),
                                    icon: const Icon(Icons.add),
                                    label: const Text('创建第一次旅行'),
                                  ),
                                ],
                              ),
                            )
                          : itinerary(trip, wide),
                    ),
                    if (wide && trip != null && editing) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 410,
                        child: ItemEditor(
                          key: ValueKey('${trip.id}:$editId:$day'),
                          store: store,
                          trip: trip,
                          day: day,
                          item: editId == null ? null : store.get(editId!),
                          onClose: () => setState(() => editing = false),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          floatingActionButton: trip == null || editing
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => openEditor(trip, null, wide),
                  icon: const Icon(Icons.add),
                  label: const Text('添加行程'),
                ),
        );
      },
    );
  }
}
