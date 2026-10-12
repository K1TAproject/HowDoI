import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'model.dart';
import 'store.dart';

void notice(BuildContext context, Object message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.toString().replaceFirst('FormatException: ', '')),
      ),
    );
Future<bool> confirm(BuildContext context, String title, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class Input extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int lines;
  const Input(this.label, this.controller, {super.key, this.lines = 1});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextField(
      controller: controller,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
    ),
  );
}

// Keep form controllers alive until the dialog's closing animation has ended.
Future<T?> formDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

Widget choice<T>(
  String label,
  T value,
  List<T> values,
  ValueChanged<T?> change, {
  String Function(T)? name,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: DropdownButtonFormField<T>(
    initialValue: value,
    key: ValueKey('$label:$value'),
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    items: values
        .map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(name?.call(v) ?? '$v', overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: change,
  ),
);

Future<String?> pickZone(BuildContext context, String current) async {
  return showDialog<String>(
    context: context,
    builder: (c) {
      var filter = '';
      return StatefulBuilder(
        builder: (c, set) {
          final zones =
              tz.timeZoneDatabase.locations.keys
                  .where((z) => z.toLowerCase().contains(filter.toLowerCase()))
                  .toList()
                ..sort();
          return AlertDialog(
            title: const Text('选择时区'),
            content: SizedBox(
              width: 430,
              height: 430,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '城市英文名，例如 Shanghai / Helsinki',
                    ),
                    onChanged: (v) => set(() => filter = v),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: zones.length,
                      itemBuilder: (c, i) => ListTile(
                        title: Text(zones[i]),
                        selected: zones[i] == current,
                        onTap: () => Navigator.pop(c, zones[i]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> editTrip(BuildContext context, Store store, [Record? trip]) async {
  final d = trip?.data ?? <String, dynamic>{};
  final name = TextEditingController(text: d['name'] ?? '');
  final days = TextEditingController(text: '${d['days'] ?? 3}');
  final start = TextEditingController(text: d['start'] ?? '');
  final note = TextEditingController(text: d['note'] ?? '');
  var base = d['base'] as String? ?? 'CNY',
      zone = d['zone'] as String? ?? 'Asia/Shanghai';
  final rates = {
    for (final c in currencies)
      c: TextEditingController(text: (d['rates'] as Map? ?? {})[c] ?? ''),
  };
  await formDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(trip == null ? '创建旅行' : '旅行设置'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Input('旅行名称 *', name),
                Input('旅行天数（1～3660）', days),
                Input('出发日期 YYYY-MM-DD（可空）', start),
                choice('主币种', base, currencies, (v) => set(() => base = v!)),
                ListTile(
                  title: const Text('默认时区'),
                  subtitle: Text(zone),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final v = await pickZone(c, zone);
                    if (v != null && c.mounted) set(() => zone = v);
                  },
                ),
                Input('旅行备注', note, lines: 3),
                ExpansionTile(
                  title: const Text('手动汇率'),
                  subtitle: Text('1 单位外币 = 多少 $base；留空为待折算'),
                  children: [
                    for (final currency in currencies.where((v) => v != base))
                      Input(currency, rates[currency]!),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              try {
                if (trip != null &&
                    store.get(trip.id)?.modified != trip.modified) {
                  throw const FormatException('旅行已在其他设备修改，请重新打开设置');
                }
                final count = int.tryParse(days.text) ?? 0;
                if (trip != null &&
                    store
                        .items(trip.id)
                        .any(
                          (r) =>
                              r.data['day'] > count ||
                              r.data['endDay'] > count + 1,
                        )) {
                  throw const FormatException('仍有活动或住宿超出新天数，请先调整');
                }
                store.save('trip', {
                  'name': name.text.trim(),
                  'days': count,
                  'start': start.text.trim(),
                  'base': base,
                  'zone': zone,
                  'note': note.text,
                  'rates': {
                    for (final e in rates.entries)
                      if (e.key != base && e.value.text.trim().isNotEmpty)
                        e.key: e.value.text.trim(),
                  },
                }, id: trip?.id);
                Navigator.pop(c);
              } catch (e) {
                notice(c, e);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  for (final x in [name, days, start, note, ...rates.values]) {
    x.dispose();
  }
}

const sharedFields = <String, String>{
  'address': '地址',
  'reference': '预订编号',
  'contact': '联系方式',
  'duration': '预计时长（分钟）',
};
const typeFields = <String, Map<String, String>>{
  '航班': {
    'carrier': '航空公司',
    'number': '航班号',
    'origin': '出发机场',
    'destination': '到达机场',
    'terminalFrom': '出发航站楼',
    'terminalTo': '到达航站楼',
    'checkIn': '值机截止时间（当地）',
    'boarding': '登机时间（当地）',
    'gate': '登机口',
    'seat': '座位',
    'class': '舱位',
    'baggage': '行李额度',
  },
  '铁路': {
    'number': '车次',
    'origin': '出发站',
    'destination': '到达站',
    'gate': '检票口',
    'platform': '站台',
    'carriage': '车厢',
    'seat': '座位',
    'class': '席别',
  },
  '市内交通': {
    'mode': '方式：步行 / 公交 / 地铁等',
    'number': '线路',
    'origin': '上车站点',
    'destination': '下车站点',
    'transfer': '换乘说明',
  },
  '长途汽车': {
    'carrier': '运营方',
    'number': '班次',
    'origin': '出发站',
    'destination': '到达站',
    'seat': '座位',
  },
  '轮渡': {
    'carrier': '运营方',
    'number': '班次',
    'origin': '出发码头',
    'destination': '到达码头',
    'seat': '座位 / 舱位',
  },
  '自驾': {'origin': '起点', 'destination': '终点', 'distance': '预计里程（公里）'},
  '租车': {
    'carrier': '租车公司',
    'vehicle': '车型',
    'origin': '取车地点',
    'destination': '还车地点',
    'distance': '预计里程（公里）',
  },
  '出租车': {'origin': '起点', 'destination': '终点', 'distance': '预计里程（公里）'},
  '住宿': {
    'roomType': '房型',
    'rooms': '房间数',
    'checkIn': '办理入住时间',
    'checkOut': '办理退房时间',
  },
  '游览': {'opening': '营业时间', 'reservation': '预约时间'},
  '餐饮': {'opening': '营业时间', 'reservation': '预约时间'},
  '购物': {'opening': '营业时间', 'reservation': '预约时间'},
  '其他': {'opening': '营业时间', 'reservation': '预约时间'},
};
bool isTransport(String type) => types.indexOf(type) >= 5;

String timeSummary(
  Record trip,
  Map<String, dynamic> d,
  String defaultZone, {
  String? endZone,
}) {
  final f = d['fields'] as Map;
  final results = <DateTime?>[];
  final messages = <String>[];
  for (final end in [false, true]) {
    final p = end ? 'end' : 'start';
    final day = d[end ? 'endDay' : 'day'] as int;
    final planned = dayDate(trip.data, day);
    final date = (f['${p}Date'] as String? ?? '').isNotEmpty
        ? f['${p}Date'] as String
        : planned;
    final time = f['${p}Time'] as String? ?? '';
    final zone = (f['${p}Zone'] as String? ?? '').isNotEmpty
        ? f['${p}Zone'] as String
        : (end ? endZone ?? defaultZone : defaultZone);
    if ((f['${p}Date'] ?? '') != '' && planned.isNotEmpty && date != planned) {
      messages.add('${end ? '到达' : '出发'}固定日期与旅行日不同，请确认');
    }
    if (date.isEmpty || time.isEmpty) {
      results.add(null);
      continue;
    }
    try {
      final instants = localInstants(date, time, zone);
      if (instants.isEmpty) {
        messages.add('$date $time 在该时区不存在，请修正');
        results.add(null);
      } else if (instants.length > 1 && (f['${p}Fold'] ?? '') == '') {
        messages.add('$date $time 因夏令时出现两次，请选择较早/较晚时刻');
        results.add(null);
      } else {
        results.add(f['${p}Fold'] == 'later' ? instants.last : instants.first);
      }
    } catch (e) {
      messages.add(e.toString());
      results.add(null);
    }
  }
  if (results.every((r) => r != null)) {
    final minutes = results[1]!.difference(results[0]!).inMinutes;
    messages.add(
      minutes < 0
          ? '结束早于开始，请确认'
          : '跨时区时长：${minutes ~/ 60} 小时 ${minutes % 60} 分钟',
    );
  }
  return messages.join('\n');
}

class ItemEditor extends StatefulWidget {
  final Store store;
  final Record trip;
  final Record? item;
  final int day;
  final VoidCallback onClose;
  const ItemEditor({
    super.key,
    required this.store,
    required this.trip,
    required this.day,
    required this.onClose,
    this.item,
  });
  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  int? openedModified;
  late Map<String, dynamic> draft;
  final fields = <String, TextEditingController>{};
  late TextEditingController name, note;
  String? error;
  @override
  void initState() {
    super.initState();
    openedModified = widget.item?.modified;
    draft = widget.item == null
        ? {
            'trip': widget.trip.id,
            'day': widget.day,
            'endDay': widget.day,
            'name': '',
            'type': '游览',
            'note': '',
            'booking': '不适用',
            'done': false,
            'fields': <String, dynamic>{},
            'costs': <dynamic>[],
          }
        : Map<String, dynamic>.from(
            jsonDecode(jsonEncode(widget.item!.data)) as Map,
          );
    name = TextEditingController(text: draft['name']);
    note = TextEditingController(text: draft['note']);
  }

  TextEditingController field(String key) => fields.putIfAbsent(
    key,
    () => TextEditingController(text: draft['fields'][key] ?? ''),
  );
  Map<String, dynamic> value() {
    final d = Map<String, dynamic>.from(draft);
    d['name'] = name.text.trim();
    d['note'] = note.text;
    d['fields'] = {
      ...draft['fields'],
      for (final e in fields.entries) e.key: e.value.text.trim(),
    };
    return d;
  }

  @override
  void dispose() {
    name.dispose();
    note.dispose();
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> cost([int? index]) async {
    final old = index == null ? null : draft['costs'][index] as Map;
    final label = TextEditingController(text: old?['label'] ?? '');
    final amount = TextEditingController(text: old?['amount'] ?? '');
    var currency =
        old?['currency'] as String? ?? widget.trip.data['base'] as String;
    var category =
        old?['category'] as String? ??
        (isTransport(draft['type'])
            ? '交通'
            : draft['type'] == '住宿'
            ? '住宿'
            : '其他');
    await formDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('预计费用'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Input('费用名称', label),
                  Input('预计金额（空为未估算，0 为免费）', amount),
                  choice(
                    '币种',
                    currency,
                    currencies,
                    (v) => set(() => currency = v!),
                  ),
                  choice(
                    '分类',
                    category,
                    categories,
                    (v) => set(() => category = v!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  if (amount.text.trim().isNotEmpty) {
                    decimalUnits(amount.text.trim(), digits(currency));
                  }
                  final entry = {
                    'id': old?['id'] ?? uuid.v4(),
                    'label': label.text.trim(),
                    'amount': amount.text.trim(),
                    'currency': currency,
                    'category': category,
                  };
                  setState(() {
                    if (index == null) {
                      draft['costs'].add(entry);
                    } else {
                      draft['costs'][index] = entry;
                    }
                  });
                  Navigator.pop(c);
                } catch (e) {
                  notice(c, e);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    label.dispose();
    amount.dispose();
  }

  void save() {
    try {
      if (widget.store.get(widget.trip.id)?.deleted != false) {
        throw const FormatException('旅行已删除');
      }
      if (widget.item != null &&
          widget.store.get(widget.item!.id)?.modified != openedModified) {
        throw const FormatException('活动已在其他设备修改，请关闭后重新打开');
      }
      final d = value();
      if (d['type'] == '住宿' && d['day'] > 0 && d['endDay'] <= d['day']) {
        throw const FormatException('住宿退房日必须晚于入住日');
      }
      if (d['booking'] == '已预订') {
        for (final end in [false, true]) {
          final key = end ? 'endDate' : 'startDate';
          if ((d['fields'][key] ?? '') == '') {
            d['fields'][key] = dayDate(
              widget.trip.data,
              d[end ? 'endDay' : 'day'],
            );
          }
        }
      }
      widget.store.save('item', d, id: widget.item?.id);
      widget.onClose();
    } catch (e) {
      setState(
        () => error = e.toString().replaceFirst('FormatException: ', ''),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = draft['type'] as String;
    final day = draft['day'] as int;
    final days = List.generate((widget.trip.data['days'] as int) + 1, (i) => i);
    final links = widget.store
        .items(widget.trip.id)
        .where((r) => r.id != widget.item?.id && !isTransport(r.data['type']))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.item == null ? '添加行程' : '行程详情',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
                tooltip: '关闭',
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Input('名称 *', name),
              choice(
                '活动类型',
                type,
                types,
                (v) => setState(() {
                  draft['type'] = v!;
                  if (v == '住宿' && draft['endDay'] <= day) {
                    draft['endDay'] = day + 1;
                  }
                }),
              ),
              choice(
                '安排到',
                day,
                days,
                (v) => setState(() {
                  draft['day'] = v!;
                  if (draft['endDay'] < v ||
                      type == '住宿' && draft['endDay'] <= v) {
                    draft['endDay'] = type == '住宿' ? v + 1 : v;
                  }
                }),
                name: (v) => v == 0 ? '待安排' : '第 $v 天',
              ),
              choice(
                type == '住宿' ? '退房日' : '结束 / 到达日',
                draft['endDay'] as int,
                List.generate((widget.trip.data['days'] as int) + 2, (i) => i),
                (v) => setState(() => draft['endDay'] = v!),
                name: (v) => v == 0 ? '未安排' : '第 $v 天',
              ),
              choice('预订状态', draft['booking'] as String, [
                '不适用',
                '待预订',
                '已预订',
              ], (v) => setState(() => draft['booking'] = v!)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('已完成'),
                value: draft['done'],
                onChanged: (v) => setState(() => draft['done'] = v),
              ),
              ExpansionTile(
                title: const Text('时间与时区'),
                initiallyExpanded: true,
                children: [
                  for (final end in [false, true]) ...[
                    Input(
                      end ? '固定结束日期 YYYY-MM-DD（可空）' : '固定开始日期 YYYY-MM-DD（可空）',
                      field(end ? 'endDate' : 'startDate'),
                    ),
                    Input(
                      end ? '结束当地时间 HH:mm' : '开始当地时间 HH:mm',
                      field(end ? 'endTime' : 'startTime'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(end ? '到达 / 结束时区' : '出发 / 开始时区'),
                      subtitle: Text(
                        field(end ? 'endZone' : 'startZone').text.isEmpty
                            ? '继承当天：${widget.store.zone(widget.trip, end ? draft['endDay'] : day)}'
                            : field(end ? 'endZone' : 'startZone').text,
                      ),
                      onTap: () async {
                        final v = await pickZone(
                          context,
                          field(end ? 'endZone' : 'startZone').text,
                        );
                        if (v != null && mounted) {
                          setState(
                            () => field(end ? 'endZone' : 'startZone').text = v,
                          );
                        }
                      },
                      trailing: IconButton(
                        tooltip: '恢复当天时区',
                        onPressed: () => setState(
                          () => field(end ? 'endZone' : 'startZone').clear(),
                        ),
                        icon: const Icon(Icons.restart_alt),
                      ),
                    ),
                    choice(
                      '夏令时重复时刻${end ? '（结束）' : '（开始）'}',
                      field(end ? 'endFold' : 'startFold').text,
                      ['', 'earlier', 'later'],
                      (v) => setState(
                        () => field(end ? 'endFold' : 'startFold').text = v!,
                      ),
                      name: (v) => v == ''
                          ? '未选择（仅遇重复时刻需选）'
                          : v == 'earlier'
                          ? '较早的时刻'
                          : '较晚的时刻',
                    ),
                  ],
                  OutlinedButton(
                    onPressed: () => setState(
                      () => error = timeSummary(
                        widget.trip,
                        value(),
                        widget.store.zone(widget.trip, day),
                        endZone: widget.store.zone(
                          widget.trip,
                          draft['endDay'],
                        ),
                      ),
                    ),
                    child: const Text('检查时间与时长'),
                  ),
                  const Text(
                    '不填固定日期时跟随旅行日；已预订且旅行有日期时，保存将固定日期。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
              if (isTransport(type))
                ExpansionTile(
                  title: const Text('连接前后地点'),
                  children: [
                    for (final end in [false, true])
                      Builder(
                        builder: (c) {
                          final key = end ? 'toId' : 'fromId';
                          final selected = field(key).text;
                          final options = ['', ...links.map((r) => r.id)];
                          if (!options.contains(selected)) {
                            options.add(selected);
                          }
                          return choice(
                            end ? '到达地点' : '出发地点',
                            selected,
                            options,
                            (v) => setState(() => field(key).text = v!),
                            name: (v) => v == ''
                                ? '暂不关联'
                                : links
                                              .where((r) => r.id == v)
                                              .firstOrNull
                                              ?.data['name']
                                          as String? ??
                                      '原地点已删除（请确认）',
                          );
                        },
                      ),
                  ],
                ),
              ExpansionTile(
                title: Text('$type详细信息'),
                initiallyExpanded: true,
                children: [
                  for (final e in {
                    ...sharedFields,
                    ...?typeFields[type],
                  }.entries)
                    Input(e.value, field(e.key)),
                ],
              ),
              Input('文字备注', note, lines: 4),
              const Divider(),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '预计费用',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: cost,
                    icon: const Icon(Icons.add),
                    tooltip: '增加费用',
                  ),
                ],
              ),
              if ((draft['costs'] as List).isEmpty)
                const Text('尚未估算。多晚住宿在这里填写整段总价。'),
              for (var i = 0; i < (draft['costs'] as List).length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${draft['costs'][i]['label']} · ${draft['costs'][i]['category']}',
                  ),
                  subtitle: Text(
                    '${draft['costs'][i]['amount'] == '' ? '未估算' : draft['costs'][i]['amount']} ${draft['costs'][i]['currency']}',
                  ),
                  onTap: () => cost(i),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '移除费用',
                    onPressed: () => setState(() => draft['costs'].removeAt(i)),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (widget.item != null)
                TextButton(
                  onPressed: () async {
                    if (await confirm(
                          context,
                          '删除活动',
                          '删除会同步到另一设备，已填写信息也会删除。',
                        ) &&
                        mounted) {
                      widget.store.remove(widget.item!);
                      widget.onClose();
                    }
                  },
                  child: const Text('删除'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: save,
                icon: const Icon(Icons.check),
                label: const Text('保存行程'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
