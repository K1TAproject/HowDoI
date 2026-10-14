import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'model.dart';
import 'store.dart';
import 'editors.dart';
import 'sync.dart';
import 'planner.dart';
import 'pickers.dart';
import 'updates.dart';
import 'day_actions.dart';

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
  bool showingUpdates = false;
  GlobalKey<ItemEditorState> editorKey = GlobalKey<ItemEditorState>();
  final expandedNotes = <String>{};
  static const windowChannel = MethodChannel('howdoi/window');
  Future<bool> leaveEditor() async =>
      await editorKey.currentState?.mayLeave() ?? true;
  Store get store => widget.store;
  @override
  void initState() {
    super.initState();
    tripId = store.setting('selectedTrip');
    day = int.tryParse(store.setting('selectedDay') ?? '1') ?? 1;
    store.addListener(changed);
    widget.sync.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    windowChannel.setMethodCallHandler((call) async {
      if (call.method == 'requestClose') {
        return !showingUpdates && await leaveEditor();
      }
      throw MissingPluginException();
    });
  }

  @override
  void dispose() {
    store.removeListener(changed);
    widget.sync.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    windowChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.sync.active = !showingUpdates && state == AppLifecycleState.resumed;
    if (widget.sync.active) widget.sync.tick();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> selectDay(int value) async {
    if (!await leaveEditor() || !mounted) return;
    setState(() {
      day = value;
      editing = false;
    });
    store.setSetting('selectedDay', '$day');
  }

  Future<void> about() async {
    if (!await leaveEditor() || !mounted) return;
    setState(() => editing = false);
    showingUpdates = true;
    widget.sync.active = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(store: store),
      );
    } finally {
      showingUpdates = false;
      widget.sync.active = true;
    }
  }

  Future<void> selectTrip(Record trip) async {
    if (!await leaveEditor() || !mounted) return;
    setState(() {
      tripId = trip.id;
      editing = false;
      final start = parseDate(trip.data['start']);
      final now = DateTime.now();
      final offset = start == null
          ? -1
          : DateTime(now.year, now.month, now.day).difference(start).inDays;
      final days = store.visibleDays(trip.id);
      day = days.contains(offset + 1) ? offset + 1 : days.firstOrNull ?? 0;
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

  Future<void> openEditor(Record trip, Record? item, bool wide) async {
    if (!await leaveEditor() || !mounted) return;
    editorKey = GlobalKey<ItemEditorState>();
    if (wide) {
      setState(() {
        editId = item?.id;
        editing = true;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (c) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) async {
              if (!didPop && await leaveEditor() && c.mounted) Navigator.pop(c);
            },
            child: Scaffold(
              body: SafeArea(
                child: ItemEditor(
                  key: editorKey,
                  store: store,
                  trip: trip,
                  day: day,
                  item: item,
                  onClose: () => Navigator.pop(c),
                ),
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
                const Text('包含尚未分配日期的历史行程；住宿只计算一次。'),
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

  Future<void> allocateHistory(Record trip) async {
    if (!await leaveEditor() || !mounted) return;
    setState(() => editing = false);
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, refresh) {
          final pending = store
              .items(trip.id)
              .where((r) => r.data['day'] == 0)
              .toList();
          return AlertDialog(
            title: const Text('为历史行程分配日期'),
            content: SizedBox(
              width: 480,
              height: 340,
              child: pending.isEmpty
                  ? const Center(child: Text('已全部分配，原有资料和预算均已保留。'))
                  : ListView(
                      children: [
                        for (final item in pending)
                          ListTile(
                            title: Text(itemTitle(item.data)),
                            subtitle: Text(itemType(item.data)),
                            trailing: const Icon(Icons.calendar_month_outlined),
                            onTap: () async {
                              final chosen = await chooseDay(
                                c,
                                trip.data,
                                day > 0 ? day : 1,
                              );
                              if (chosen == null || !c.mounted) return;
                              int? endDay;
                              if (item.data['type'] == '住宿' &&
                                  item.data['endDay'] > 0 &&
                                  item.data['endDay'] <= chosen) {
                                if (!await confirm(
                                      c,
                                      '选择退房日',
                                      '原退房日不晚于新入住日，请选择新的退房日。',
                                    ) ||
                                    !c.mounted) {
                                  return;
                                }
                                endDay = await chooseDay(
                                  c,
                                  trip.data,
                                  chosen + 1,
                                );
                                if (endDay == null || !c.mounted) return;
                              }
                              try {
                                store.assignDay(item, chosen, endDay: endDay);
                                refresh(() {});
                              } catch (e) {
                                notice(c, e);
                              }
                            },
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> tripAction(Record trip, String action) async {
    if (!await leaveEditor() || !mounted) return;
    setState(() => editing = false);
    final current = store.get(trip.id);
    if (current == null || current.deleted) return;
    switch (action) {
      case 'edit':
        await editTrip(context, store, current);
      case 'export':
        await backup(current);
      case 'delete':
        if (await confirm(
          context,
          '删除旅行 · ${current.data['name']}',
          '整趟旅行将被删除并同步。建议先导出备份。',
        )) {
          store.remove(current);
        }
    }
  }

  Future<void> dayAction(Record trip, int source, String action) async {
    if (!await leaveEditor() || !mounted) return;
    final wasSelected = day == source;
    setState(() => editing = false);
    try {
      final selected = await changeTravelDay(
        context,
        store,
        trip,
        source,
        deleting: action == 'delete',
        onUndo: () {
          if (mounted) selectDay(source);
        },
      );
      if (selected != null && mounted && wasSelected) {
        setState(() => day = selected);
        store.setSetting('selectedDay', '$day');
      }
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  Widget navigation(Record? trip) {
    Widget action(String label, VoidCallback onPressed) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(42),
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.add, size: 20),
        label: Text(label),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('我的旅行', style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final t in store.trips)
          _NavigationCard(
            title: t.data['name'],
            subtitle:
                '${store.visibleDays(t.id).length} 个旅行日 · ${t.data['start'] == '' ? '日期待定' : t.data['start']}',
            selected: t.id == trip?.id,
            onTap: () => selectTrip(t),
            menu: PopupMenuButton<String>(
              tooltip: '旅行操作：${t.data['name']}',
              icon: const Icon(Icons.more_horiz),
              onSelected: (v) => tripAction(t, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑旅行')),
                PopupMenuItem(value: 'export', child: Text('导出本次旅行')),
                PopupMenuItem(value: 'delete', child: Text('删除旅行')),
              ],
            ),
          ),
        action('创建旅行', () async {
          if (await leaveEditor() && mounted) {
            setState(() => editing = false);
            await editTrip(context, store);
          }
        }),
        if (trip != null) ...[
          const SizedBox(height: 20),
          action('添加日期', () async {
            if (!await leaveEditor() || !mounted) return;
            try {
              final added = store.addDay(trip);
              setState(() {
                day = added;
                editing = false;
              });
              store.setSetting('selectedDay', '$added');
            } catch (e) {
              if (mounted) notice(context, e);
            }
          }),
          for (final i in store.visibleDays(trip.id))
            _NavigationCard(
              title: dayTitle(trip, i),
              subtitle: daySubtitle(trip, i),
              selected: day == i,
              onTap: () => selectDay(i),
              menu: PopupMenuButton<String>(
                tooltip: '日期操作：第 $i 天',
                icon: const Icon(Icons.more_horiz),
                onSelected: (v) => dayAction(trip, i, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'move', child: Text('调整日期')),
                  PopupMenuItem(value: 'delete', child: Text('删除日期')),
                ],
              ),
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
    final rows = store
        .timeline(trip.id, r.data['day'])
        .map((n) => n.item)
        .toList();
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

  Widget itemCard(PlanNode node, Record trip, bool wide, {String? hour}) {
    final r = node.item, d = r.data;
    final type = itemType(d), f = d['fields'] as Map;
    final warning = [
      dateWarning(trip, d),
      linkWarning(r, trip),
    ].where((s) => s.isNotEmpty).join('\n');
    final info = <String>[];
    if (scheduledTransport(type)) {
      if (fieldText(d, 'number').isNotEmpty) info.add(fieldText(d, 'number'));
      for (final end in [false, true]) {
        final place = fieldText(d, end ? 'destination' : 'origin');
        final terminal = fieldText(d, end ? 'terminalTo' : 'terminalFrom');
        final date = itemDate(trip, d, end);
        final time = fieldText(d, end ? 'endTime' : 'startTime');
        info.add(
          [
            end ? '到达' : '出发',
            place,
            terminal,
            if (date.isNotEmpty && (end || dateWarning(trip, d).isNotEmpty))
              date,
            time,
          ].where((x) => x.isNotEmpty).join(' · '),
        );
      }
    }
    if (type == '住宿') {
      final start = itemDate(trip, d, false), end = itemDate(trip, d, true);
      info.add(
        '${start.isEmpty
            ? d['day'] == 0
                  ? '入住日待定'
                  : '第 ${d['day']} 天'
            : start} 入住 → ${end.isEmpty
            ? d['endDay'] == 0
                  ? '退房日待定'
                  : '第 ${d['endDay']} 天退房'
            : '$end 退房'}',
      );
      if (d['endDay'] > d['day'] && d['day'] > 0) {
        info.add('共 ${d['endDay'] - d['day']} 晚');
      }
    }
    if (type == '租车') {
      info.add(fieldText(d, node.end ? 'destination' : 'origin'));
    }
    if (fieldText(d, 'address').isNotEmpty) info.add(fieldText(d, 'address'));
    final detail = <String>[];
    for (final entry in {
      if (type == '交通/移动') ...{'mode': '', 'number': '', 'transfer': ''},
      if (isTransport(type)) 'gate': type == '航班' ? '登机口' : '检票/登船口',
      if (['铁路', '长途汽车', '轮渡'].contains(type)) ...{
        'platform': '站台',
        'carriage': '车厢',
        'seat': '座位/铺位',
      },
    }.entries) {
      if (fieldText(d, entry.key).isNotEmpty) {
        detail.add('${entry.value} ${fieldText(d, entry.key)}'.trim());
      }
    }
    if (detail.isNotEmpty) info.add(detail.join(' · '));
    if (fieldText(d, 'duration').isNotEmpty) {
      info.add('预计 ${durationText(fieldText(d, 'duration'))}');
    }
    if (fieldText(d, 'reservationTime').isNotEmpty) {
      info.add(
        '预约 ${fieldText(d, 'reservationDate')} ${fieldText(d, 'reservationTime')}',
      );
    }
    if (fieldText(d, 'reservation').isNotEmpty) {
      info.add('预约信息：${f['reservation']}');
    }
    if (d['booking'] != '不适用') info.add(d['booking']);
    return Padding(
      key: ValueKey(node.id),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hour != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 12, bottom: 4),
              child: Text(
                '$hour:00',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              onTap: () => openEditor(trip, r, wide),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 32, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: wide ? 78 : 56,
                      child: Column(
                        children: [
                          Text(
                            node.stay
                                ? '住宿'
                                : node.time.isEmpty
                                ? '—'
                                : node.time,
                            style: TextStyle(
                              fontSize: wide ? 17 : 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (node.appointment)
                            const Text('预约', style: TextStyle(fontSize: 11)),
                          Checkbox(
                            value: d['done'],
                            onChanged: (v) {
                              store.save('item', {...d, 'done': v}, id: r.id);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${node.prefix}${itemTitle(d)}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              decoration: d['done']
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          Text(
                            type,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          for (final line in info.where((s) => s.isNotEmpty))
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(line),
                            ),
                          if ((d['note'] as String).isNotEmpty)
                            InkWell(
                              onTap: () => setState(() {
                                if (!expandedNotes.add(r.id)) {
                                  expandedNotes.remove(r.id);
                                }
                              }),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  '备注 · ${d['note']}',
                                  maxLines: expandedNotes.contains(r.id)
                                      ? null
                                      : 1,
                                  overflow: expandedNotes.contains(r.id)
                                      ? null
                                      : TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          if (warning.isNotEmpty)
                            Text(
                              warning,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget itinerary(Record trip, bool wide) {
    final rows = day == 0 ? <PlanNode>[] : store.timeline(trip.id, day);
    final stays = planNodes(
      store.items(trip.id),
    ).where((n) => n.stay && n.day == day).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (store.items(trip.id).any((r) => r.data['day'] == 0))
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: () => allocateHistory(trip),
              label: Text(
                '为 ${store.items(trip.id).where((r) => r.data['day'] == 0).length} 条历史行程分配日期',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                day == 0 ? '从第一天开始' : dayTitle(trip, day),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 5),
              if (day != 0 && daySubtitle(trip, day).isNotEmpty)
                Text(daySubtitle(trip, day)),
              Text(day == 0 ? '点击左侧“添加日期”，再安排当天行程。' : '按时间规划 · 未定时间的安排可拖动穿插'),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: true,
            itemCount: rows.length,
            header: rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有安排，添加第一站吧。'),
                  )
                : null,
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (stays.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '当晚住宿',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                for (final stay in stays) itemCard(stay, trip, wide),
                const SizedBox(height: 96),
              ],
            ),
            itemBuilder: (c, i) {
              final hour = rows[i].time.isEmpty || day == 0
                  ? null
                  : rows[i].time.split(':').first;
              final previous = rows
                  .take(i)
                  .where((r) => r.time.isNotEmpty)
                  .lastOrNull
                  ?.time
                  .split(':')
                  .first;
              return itemCard(
                rows[i],
                trip,
                wide,
                hour: hour != previous ? hour : null,
              );
            },
            onReorderItem: (a, b) {
              final moved = rows[a];
              final proposed = [...rows];
              proposed.insert(b, proposed.removeAt(a));
              final timed = proposed
                  .where((n) => n.time.isNotEmpty)
                  .map((n) => n.time)
                  .toList();
              if (day != 0 &&
                  moved.time.isNotEmpty &&
                  !List.generate(
                    timed.isNotEmpty ? timed.length - 1 : 0,
                    (i) => timed[i].compareTo(timed[i + 1]) <= 0,
                  ).every((x) => x)) {
                notice(context, '已定时行程按时间排序，请修改时间来调整顺序');
                return;
              }
              store.reorder(trip.id, day, proposed.map((n) => n.id).toList());
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
    if (trip != null && !editing && !store.visibleDays(trip.id).contains(day)) {
      day = store.visibleDays(trip.id).firstOrNull ?? 0;
    }
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 1100;
        final sidebar = size.maxWidth >= 800;
        return Scaffold(
          appBar: AppBar(
            title: Text(trip?.data['name'] ?? 'HowDoI'),
            actions: [
              IconButton(
                tooltip: '关于 / 检查更新',
                onPressed: about,
                icon: const Icon(Icons.info_outline),
              ),
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
              ],
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (!await leaveEditor() || !context.mounted) return;
                  setState(() => editing = false);
                  switch (v) {
                    case 'all':
                      await backup(null);
                    case 'import':
                      await importBackup();
                  }
                },
                itemBuilder: (c) => [
                  const PopupMenuItem(value: 'all', child: Text('导出全部旅行')),
                  const PopupMenuItem(value: 'import', child: Text('导入备份副本')),
                ],
              ),
            ],
          ),
          drawer: sidebar
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
                        const Text(
                          '离线可用 · 编辑后保存',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    if (sidebar) ...[
                      SizedBox(
                        width: 230,
                        child: Material(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          child: navigation(trip),
                        ),
                      ),
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
                                    onPressed: () async {
                                      if (await leaveEditor() &&
                                          context.mounted) {
                                        setState(() => editing = false);
                                        await editTrip(context, store);
                                      }
                                    },
                                    icon: const Icon(Icons.add),
                                    label: const Text('创建第一次旅行'),
                                  ),
                                ],
                              ),
                            )
                          : editing && !wide
                          ? ItemEditor(
                              key: editorKey,
                              store: store,
                              trip: trip,
                              day: day,
                              item: editId == null ? null : store.get(editId!),
                              onClose: () => setState(() => editing = false),
                            )
                          : itinerary(trip, wide),
                    ),
                    if (wide && trip != null && editing) ...[
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 410,
                        child: Material(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          child: ItemEditor(
                            key: editorKey,
                            store: store,
                            trip: trip,
                            day: day,
                            item: editId == null ? null : store.get(editId!),
                            onClose: () => setState(() => editing = false),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          floatingActionButton: trip == null || day == 0 || editing
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

class _NavigationCard extends StatefulWidget {
  final String title, subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget menu;
  const _NavigationCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    required this.menu,
  });
  @override
  State<_NavigationCard> createState() => _NavigationCardState();
}

class _NavigationCardState extends State<_NavigationCard> {
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: widget.selected
            ? colors.primaryContainer
            : colors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: focused ? colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Focus(
          onFocusChange: (v) => setState(() => focused = v),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: widget.onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 0, 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: widget.selected
                              ? const Icon(
                                  Icons.check,
                                  size: 17,
                                  semanticLabel: '当前选中',
                                )
                              : null,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                style: TextStyle(
                                  fontWeight: widget.selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                              if (widget.subtitle.isNotEmpty)
                                Text(
                                  widget.subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              widget.menu,
            ],
          ),
        ),
      ),
    );
  }
}
