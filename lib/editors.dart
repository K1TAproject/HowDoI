import 'dart:convert';
import 'package:flutter/material.dart';
import 'planner.dart';
import 'pickers.dart';
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
        isDense: true,
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
    decoration: InputDecoration(labelText: label),
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

Future<void> editTrip(BuildContext context, Store store, [Record? trip]) async {
  final d = trip?.data ?? <String, dynamic>{};
  final name = TextEditingController(text: d['name'] ?? '');
  final start = TextEditingController(text: d['start'] ?? '');
  final note = TextEditingController(text: d['note'] ?? '');
  var base = d['base'] as String? ?? 'CNY';
  await formDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(trip == null ? '创建旅行' : '旅行设置'),
        content: SizedBox(
          width: 520,
          height: (MediaQuery.sizeOf(c).height - 240).clamp(200.0, 480.0),
          child: PickerRegion(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Input('旅行名称 *', name),
                  PickField(
                    '出发日期',
                    start.text,
                    onTap: (anchor) async {
                      final v = await calendarDate(anchor, start.text);
                      if (v != null && c.mounted) set(() => start.text = v);
                    },
                    onClear: () => set(start.clear),
                  ),
                  choice(
                    '默认预算币种',
                    base,
                    currencies,
                    (v) => set(() => base = v!),
                  ),
                  Input('旅行备注', note, lines: 3),
                ],
              ),
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
                store.save('trip', {
                  ...d,
                  'name': name.text.trim(),
                  'days': d['days'] ?? 1,
                  'start': start.text.trim(),
                  'base': base,
                  'zone': d['zone'] ?? 'Asia/Shanghai',
                  'note': note.text,
                  'rates': d['rates'] ?? <String, dynamic>{},
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
  for (final x in [name, start, note]) {
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
  State<ItemEditor> createState() => ItemEditorState();
}

class ItemEditorState extends State<ItemEditor> {
  final pickerKey = GlobalKey<PickerRegionState>();
  int? openedModified;
  late String initialValue;
  late int tripModified;
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
            'type': '游览/活动',
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
    tripModified = widget.trip.modified;
    draft['type'] = itemType(draft);
    if (widget.item?.data['type'] == '自驾' &&
        (draft['fields']['mode'] ?? '') == '') {
      draft['fields']['mode'] = '自驾';
    }
    if (widget.item?.data['type'] == '出租车' &&
        (draft['fields']['mode'] ?? '') == '') {
      draft['fields']['mode'] = '打车';
    }
    initialValue = jsonEncode(value());
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
      for (final e in fields.entries)
        if (e.value.text.trim().isNotEmpty ||
            (draft['fields'] as Map).containsKey(e.key))
          e.key: e.value.text.trim(),
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

  bool save({bool close = true}) {
    try {
      final trip = widget.store.get(widget.trip.id);
      if (trip?.deleted != false) throw const FormatException('旅行已删除');
      if (trip!.modified != tripModified) {
        throw const FormatException('旅行设置已改变，请关闭后重新打开');
      }
      if (widget.item != null &&
          widget.store.get(widget.item!.id)?.modified != openedModified) {
        throw const FormatException('活动已在其他设备修改，请关闭后重新打开');
      }
      final d = value();
      if (d['day'] == 0) throw const FormatException('请先为行程选择旅行日');
      if (d['booking'] == '已预订') {
        for (final end in [false, true]) {
          final key = end ? 'endDate' : 'startDate';
          if ((d['fields'][key] ?? '') == '') {
            d['fields'][key] = dayDate(trip.data, d[end ? 'endDay' : 'day']);
          }
        }
      }
      widget.store.save('item', d, id: widget.item?.id);
      initialValue = jsonEncode(value());
      if (close) widget.onClose();
      return true;
    } catch (e) {
      setState(
        () => error = e.toString().replaceFirst('FormatException: ', ''),
      );
      return false;
    }
  }

  Future<bool> mayLeave() async {
    if (pickerKey.currentState?.dismissIfOpen() ?? false) return false;
    if (initialValue == jsonEncode(value())) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('尚未保存的修改'),
        content: const Text('是否保存当前行程？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    return answer == 'discard' || (answer == 'save' && save(close: false));
  }

  Widget clock(String key, String label, {bool duration = false}) {
    final controller = field(key);
    return PickField(
      label,
      duration ? durationText(controller.text) : controller.text,
      onTap: (anchor) async {
        final v = await clockValue(anchor, controller.text, duration: duration);
        if (v != null && mounted) {
          setState(() => controller.text = v);
        }
      },
      onClear: () => setState(controller.clear),
    );
  }

  Widget date(bool end, String label) {
    final key = end ? 'endDate' : 'startDate', dayKey = end ? 'endDay' : 'day';
    final controller = field(key);
    final value = controller.text.isNotEmpty
        ? controller.text
        : draft[dayKey] == 0
        ? ''
        : dayDate(widget.trip.data, draft[dayKey]).isNotEmpty
        ? dayDate(widget.trip.data, draft[dayKey])
        : '第 ${draft[dayKey]} 天';
    return PickField(
      label,
      value,
      onTap: (anchor) async {
        final selected = await chooseDay(
          anchor,
          widget.trip.data,
          draft[dayKey],
          existing: controller.text,
        );
        if (selected != null && mounted) {
          setState(() {
            final oldDay = draft['day'];
            draft[dayKey] = selected;
            controller.text = dayDate(widget.trip.data, selected);
            if (!end && draft['endDay'] == oldDay && draft['type'] != '住宿') {
              draft['endDay'] = selected;
              field('endDate').text = dayDate(widget.trip.data, selected);
            }
          });
        }
      },
      onClear: () => setState(() {
        controller.clear();
        if (end) draft[dayKey] = 0;
      }),
    );
  }

  Widget detail(String key, String label) {
    final text = field(key).text;
    if (['checkIn', 'checkOut', 'boarding'].contains(key) &&
        (text.isEmpty || RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(text))) {
      return clock(key, label);
    }
    return Input(label, field(key));
  }

  @override
  Widget build(BuildContext context) {
    final type = draft['type'] as String;
    final transport = isTransport(type), scheduled = scheduledTransport(type);
    final stay = type == '住宿', rental = type == '租车';
    final mainKeys = <String>{};
    final main = <Widget>[];
    void add(String key, String label) {
      mainKeys.add(key);
      main.add(detail(key, label));
    }

    if (!transport) main.add(Input(stay ? '住宿名称（可空）' : '地点或安排内容（可空）', name));
    if (scheduled) {
      add(
        'number',
        type == '航班'
            ? '航班号'
            : type == '铁路'
            ? '车次'
            : '班次（可空）',
      );
    }
    if (transport) {
      final labels = typeFields[type] ?? const <String, String>{};
      Widget pair(Widget left, Widget right) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 8),
          Expanded(child: right),
        ],
      );
      for (final end in [false, true]) {
        final key = end ? 'destination' : 'origin';
        mainKeys.add(key);
        final place = detail(key, labels[key] ?? (end ? '终点' : '起点'));
        if (type == '航班') {
          final terminal = end ? 'terminalTo' : 'terminalFrom';
          mainKeys.add(terminal);
          main.add(
            Row(
              children: [
                Expanded(flex: 2, child: place),
                const SizedBox(width: 8),
                Expanded(child: detail(terminal, end ? '到达航站楼' : '出发航站楼')),
              ],
            ),
          );
        } else {
          main.add(place);
        }
        if (scheduled || rental) {
          main.add(
            pair(
              date(
                end,
                rental ? (end ? '还车日期' : '取车日期') : (end ? '到达日期' : '出发日期'),
              ),
              clock(
                end ? 'endTime' : 'startTime',
                rental ? (end ? '还车时间' : '取车时间') : (end ? '到达时间' : '出发时间'),
              ),
            ),
          );
        }
      }
      if (!scheduled && !rental) {
        main.add(date(false, '安排日期'));
        main.add(clock('startTime', '出发时间'));
        main.add(clock('duration', '预计耗时', duration: true));
        mainKeys.add('duration');
      }
      if (rental) add('carrier', '租车公司（可空）');
    } else {
      add('address', '地址 / 位置（可空）');
      main.add(date(false, stay ? '入住日期' : '安排日期'));
      if (stay) main.add(date(true, '退房日期'));
      main.add(clock('startTime', stay ? '计划入住时间' : '计划开始时间'));
      if (stay) {
        main.add(clock('endTime', '计划退房时间'));
        if (draft['endDay'] > draft['day'] && draft['day'] > 0) {
          main.add(Text('共 ${draft['endDay'] - draft['day']} 晚'));
        }
      } else {
        mainKeys.add('duration');
        main.add(clock('duration', '预计停留时长', duration: true));
      }
    }
    final extra =
        <String, String>{
          ...sharedFields,
          ...?typeFields[type == '游览/活动' ? '游览' : type],
          if (type == '交通/移动') ...{
            'mode': '交通方式（可空）',
            'number': '线路（可空）',
            'transfer': '换乘说明',
          },
          if (stay) ...{'checkIn': '酒店最早入住时间', 'checkOut': '酒店最晚退房时间'},
          if (['长途汽车', '轮渡'].contains(type)) ...{
            'gate': '乘车口 / 登船口',
            'platform': '站台',
          },
        }..removeWhere(
          (key, _) =>
              mainKeys.contains(key) ||
              key == 'duration' ||
              (key == 'reservation' && field(key).text.isEmpty),
        );
    final known = {
      ...extra.keys,
      ...mainKeys,
      'duration',
      'startDate',
      'endDate',
      'startTime',
      'endTime',
      'startZone',
      'endZone',
      'startFold',
      'endFold',
      'fromId',
      'toId',
      'reservationDate',
      'reservationTime',
    };
    for (final key in (draft['fields'] as Map).keys.cast<String>()) {
      if (!known.contains(key) && field(key).text.isNotEmpty) {
        extra[key] = '已有信息 · $key';
      }
    }
    final links = widget.store
        .items(widget.trip.id)
        .where((r) => r.id != widget.item?.id && !isTransport(r.data['type']))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.item == null ? '添加行程' : '行程详情',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () async {
                  if (await mayLeave() && mounted) widget.onClose();
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: PickerRegion(
            key: pickerKey,
            handleBack: false,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                choice(
                  '活动类型',
                  type,
                  editorTypes,
                  (v) => setState(() {
                    draft['type'] = v!;
                    if (v == '住宿' && draft['endDay'] <= draft['day']) {
                      draft['endDay'] = 0;
                      field('endDate').clear();
                    }
                  }),
                ),
                ...main,
                if (scheduled || stay || rental)
                  choice('预订状态', draft['booking'] as String, [
                    '不适用',
                    '待预订',
                    '已预订',
                  ], (v) => setState(() => draft['booking'] = v!)),
                if (dateWarning(widget.trip, value()).isNotEmpty)
                  Text(
                    dateWarning(widget.trip, value()),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Input('备注', note, lines: 3),
                ExpansionTile(
                  title: const Text('补充信息'),
                  children: [
                    if (transport) Input('自定义名称（可空）', name),
                    if (!scheduled &&
                        !rental &&
                        !stay &&
                        (fieldText(draft, 'endTime').isNotEmpty ||
                            fieldText(draft, 'endDate').isNotEmpty)) ...[
                      date(true, '已有结束日期'),
                      clock('endTime', '已有结束时间'),
                    ],
                    for (final e in extra.entries) detail(e.key, e.value),
                    if (!mainKeys.contains('duration') &&
                        field('duration').text.isNotEmpty)
                      clock('duration', '已有预计时长', duration: true),
                    if (!transport && !stay) ...[
                      clock('reservationTime', '预约时间'),
                      PickField(
                        '预约日期',
                        field('reservationDate').text,
                        onTap: (anchor) async {
                          final v = await calendarDate(
                            anchor,
                            field('reservationDate').text,
                            fallback: dayDate(widget.trip.data, draft['day']),
                          );
                          if (v != null && mounted) {
                            setState(() => field('reservationDate').text = v);
                          }
                        },
                        onClear: () => setState(field('reservationDate').clear),
                      ),
                      choice('预约状态', draft['booking'] as String, [
                        '不适用',
                        '待预订',
                        '已预订',
                      ], (v) => setState(() => draft['booking'] = v!)),
                    ],
                    if (transport)
                      for (final end in [false, true])
                        Builder(
                          builder: (_) {
                            final key = end ? 'toId' : 'fromId';
                            final options = {
                              '',
                              field(key).text,
                              ...links.map((r) => r.id),
                            }.toList();
                            return choice(
                              end ? '从已有地点选择终点' : '从已有地点选择起点',
                              field(key).text,
                              options,
                              (v) => setState(() {
                                field(key).text = v!;
                                final match = links
                                    .where((r) => r.id == v)
                                    .firstOrNull;
                                if (match != null) {
                                  field(end ? 'destination' : 'origin').text =
                                      itemTitle(match.data);
                                }
                              }),
                              name: (v) => v == ''
                                  ? '不关联'
                                  : links.where((r) => r.id == v).firstOrNull ==
                                        null
                                  ? '原地点已删除'
                                  : itemTitle(
                                      links.firstWhere((r) => r.id == v).data,
                                    ),
                            );
                          },
                        ),
                  ],
                ),
                ExpansionTile(
                  title: const Text('预计预算'),
                  children: [
                    TextButton.icon(
                      onPressed: cost,
                      icon: const Icon(Icons.add),
                      label: const Text('增加费用'),
                    ),
                    for (var i = 0; i < (draft['costs'] as List).length; i++)
                      ListTile(
                        title: Text(
                          '${draft['costs'][i]['label']} · ${draft['costs'][i]['amount']} ${draft['costs'][i]['currency']}',
                        ),
                        onTap: () => cost(i),
                        trailing: IconButton(
                          tooltip: '移除费用',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              setState(() => draft['costs'].removeAt(i)),
                        ),
                      ),
                  ],
                ),
                SwitchListTile(
                  title: const Text('已完成'),
                  value: draft['done'],
                  onChanged: (v) => setState(() => draft['done'] = v),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (widget.item != null)
                TextButton(
                  onPressed: () async {
                    if (await confirm(context, '删除活动', '删除此行程及其关联显示？') &&
                        mounted) {
                      widget.store.remove(widget.store.get(widget.item!.id)!);
                      widget.onClose();
                    }
                  },
                  child: const Text('删除'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => save(),
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
