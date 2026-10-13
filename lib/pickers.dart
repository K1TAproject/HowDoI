import 'package:flutter/material.dart';
import 'model.dart';

Future<String?> calendarDate(BuildContext context, String current) async {
  final selected = await showDatePicker(
    context: context,
    initialDate: parseDate(current) ?? DateTime.now(),
    firstDate: DateTime(1900),
    lastDate: DateTime(2200, 12, 31),
    initialEntryMode: DatePickerEntryMode.calendarOnly,
  );
  return selected == null ? null : dateText(selected);
}

Future<String?> clockValue(
  BuildContext context,
  String current, {
  bool duration = false,
}) async {
  final parts = current.split(':');
  final total = (int.tryParse(current) ?? 0).clamp(0, 10080);
  var hour = duration ? total ~/ 60 : int.tryParse(parts.first) ?? 0;
  var minute = duration
      ? total % 60
      : parts.length == 2
      ? int.tryParse(parts.last) ?? 0
      : 0;
  return showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(duration ? '选择预计时长' : '选择时间 · 24小时制'),
        content: SizedBox(
          width: 300,
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: hour,
                  decoration: InputDecoration(labelText: duration ? '小时' : '时'),
                  items: List.generate(
                    duration ? (hour > 168 ? hour + 1 : 169) : 24,
                    (i) => DropdownMenuItem(value: i, child: Text('$i')),
                  ),
                  onChanged: (v) => set(() => hour = v!),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: minute,
                  decoration: const InputDecoration(labelText: '分'),
                  items: List.generate(
                    60,
                    (i) => DropdownMenuItem(
                      value: i,
                      child: Text(i.toString().padLeft(2, '0')),
                    ),
                  ),
                  onChanged: (v) => set(() => minute = v!),
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
          FilledButton(
            onPressed: () => Navigator.pop(
              c,
              duration
                  ? '${hour * 60 + minute}'
                  : '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

Future<int?> chooseDay(
  BuildContext context,
  Map<String, dynamic> trip,
  int current,
) async {
  final start = parseDate(trip['start'] ?? '');
  if (start != null) {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime(
        start.year,
        start.month,
        start.day + (current > 0 ? current - 1 : 0),
      ),
      firstDate: start,
      lastDate: DateTime(start.year, start.month, start.day + 3659),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (selected == null) return null;
    return DateTime.utc(
          selected.year,
          selected.month,
          selected.day,
        ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
        1;
  }
  return showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('选择旅行日'),
      content: SizedBox(
        width: 320,
        height: 360,
        child: ListView.builder(
          controller: ScrollController(
            initialScrollOffset: ((current > 0 ? current : 1) - 1) * 48.0,
          ),
          itemExtent: 48,
          itemCount: 3660,
          itemBuilder: (_, i) => ListTile(
            title: Text('第 ${i + 1} 天'),
            selected: current == i + 1,
            onTap: () => Navigator.pop(c, i + 1),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      ],
    ),
  );
}

class PickField extends StatelessWidget {
  final String label, value;
  final VoidCallback onTap, onClear;
  const PickField(
    this.label,
    this.value, {
    super.key,
    required this.onTap,
    required this.onClear,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(value.isEmpty ? '点击选择（可留空）' : value),
              ),
            ),
          ),
          if (value.isNotEmpty)
            IconButton(
              tooltip: '清除$label',
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(26, 32),
              ),
              constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 18),
            ),
          IconButton(
            tooltip: '选择$label',
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(26, 32),
            ),
            constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: onTap,
            icon: const Icon(Icons.expand_more),
          ),
        ],
      ),
    ),
  );
}
