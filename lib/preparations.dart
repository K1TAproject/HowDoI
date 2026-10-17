import 'dart:convert';
import 'package:flutter/material.dart';
import 'model.dart';
import 'store.dart';
import 'editors.dart';
import 'pickers.dart';

class PreparationList extends StatefulWidget {
  final Store store;
  final Record trip;
  final Future<bool> Function() beforeChange;
  final ValueChanged<String> onEdit;
  const PreparationList({
    super.key,
    required this.store,
    required this.trip,
    required this.beforeChange,
    required this.onEdit,
  });
  @override
  State<PreparationList> createState() => PreparationListState();
}

class PreparationListState extends State<PreparationList> {
  final name = TextEditingController();
  bool completedExpanded = false;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<bool> add({bool check = true}) async {
    if (name.text.trim().isEmpty) return false;
    if (check && !await widget.beforeChange() || !mounted) return false;
    try {
      final trip = widget.store.get(widget.trip.id)!;
      widget.store.savePreparations(trip, [
        ...widget.store.preparations(trip),
        {
          'id': uuid.v4(),
          'name': name.text.trim(),
          'due': '',
          'note': '',
          'done': false,
        },
      ]);
      name.clear();
      return true;
    } catch (e) {
      if (mounted) notice(context, e);
      return false;
    }
  }

  Future<bool> mayLeave() async {
    if (name.text.trim().isEmpty) return true;
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('尚未添加的准备事项'),
        content: const Text('是否添加输入的事项？'),
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
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (result == 'discard') {
      name.clear();
      return true;
    }
    return result == 'save' && await add(check: false);
  }

  Future<void> change(List<Map<String, dynamic>> entries) async {
    final originalTrip = widget.trip;
    if (!await widget.beforeChange() || !mounted) return;
    try {
      widget.store.savePreparations(originalTrip, entries);
    } catch (e) {
      if (mounted) notice(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.store.preparations(widget.trip);
    final pending = entries.where((p) => p['done'] == false).toList();
    final completed = entries.where((p) => p['done'] == true).toList();
    Widget row(Map<String, dynamic> p, {int? index}) => Card(
      key: ValueKey(p['id']),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: () => widget.onEdit(p['id']),
        leading: Checkbox(
          value: p['done'],
          onChanged: (v) => change([
            for (final entry in entries)
              entry['id'] == p['id'] ? {...entry, 'done': v} : entry,
          ]),
        ),
        title: Text(
          p['name'],
          style: TextStyle(
            decoration: p['done'] ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: p['due'] == '' ? null : Text('截止 ${p['due']}'),
        trailing: index == null
            ? null
            : ReorderableDragStartListener(
                index: index,
                child: const SizedBox(
                  width: 44,
                  height: 48,
                  child: Icon(Icons.drag_handle, semanticLabel: '拖动准备事项'),
                ),
              ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '预备工作 · ${completed.length}/${entries.length}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            maxLength: 200,
            onSubmitted: (_) => add(),
            decoration: InputDecoration(
              labelText: '准备事项名称',
              hintText: '输入名称，回车添加',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: '添加准备事项',
                onPressed: () => add(),
                icon: const Icon(Icons.add),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: pending.length,
              itemBuilder: (_, i) => row(pending[i], index: i),
              onReorderItem: (a, b) {
                final ordered = [...pending];
                ordered.insert(b, ordered.removeAt(a));
                change([...ordered, ...completed]);
              },
              header: pending.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('暂无未完成事项'),
                    )
                  : null,
              footer: completed.isEmpty
                  ? null
                  : ExpansionTile(
                      title: Text('已完成 ${completed.length} 项'),
                      initiallyExpanded: completedExpanded,
                      onExpansionChanged: (v) => completedExpanded = v,
                      children: [
                        ReorderableListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          itemCount: completed.length,
                          itemBuilder: (_, i) => row(completed[i], index: i),
                          onReorderItem: (a, b) {
                            final ordered = [...completed];
                            ordered.insert(b, ordered.removeAt(a));
                            change([...pending, ...ordered]);
                          },
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class PreparationEditor extends StatefulWidget {
  final Store store;
  final Record trip;
  final String id;
  final VoidCallback onClose;
  const PreparationEditor({
    super.key,
    required this.store,
    required this.trip,
    required this.id,
    required this.onClose,
  });
  @override
  State<PreparationEditor> createState() => PreparationEditorState();
}

class PreparationEditorState extends State<PreparationEditor> {
  final pickerKey = GlobalKey<PickerRegionState>();
  late Record originalTrip = widget.trip;
  late Map<String, dynamic> original = widget.store
      .preparations(originalTrip)
      .firstWhere((p) => p['id'] == widget.id);
  late final name = TextEditingController(text: original['name']);
  late final note = TextEditingController(text: original['note']);
  late String due = original['due'];
  late bool done = original['done'];
  String? error;
  Map<String, dynamic> value() => {
    ...original,
    'name': name.text.trim(),
    'note': note.text,
    'due': due,
    'done': done,
  };
  @override
  void dispose() {
    name.dispose();
    note.dispose();
    super.dispose();
  }

  bool save() {
    try {
      widget.store.savePreparations(originalTrip, [
        for (final p in widget.store.preparations(originalTrip))
          p['id'] == widget.id ? value() : p,
      ]);
      original = value();
      originalTrip = widget.store.get(originalTrip.id)!;
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
    if (jsonEncode(value()) == jsonEncode(original)) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('尚未保存的修改'),
        content: const Text('是否保存当前准备事项？'),
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
    return answer == 'discard' || answer == 'save' && save();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '准备事项',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: '关闭准备事项',
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Input('事项名称 *', name),
              PickField(
                '截止日期',
                due,
                onTap: (anchor) async {
                  final selected = await calendarDate(
                    anchor,
                    due,
                    fallback: widget.trip.data['start'],
                  );
                  if (selected != null && mounted) {
                    setState(() => due = selected);
                  }
                },
                onClear: () => setState(() => due = ''),
              ),
              Input('备注', note, lines: 5),
              SwitchListTile(
                title: const Text('已完成'),
                value: done,
                onChanged: (v) => setState(() => done = v),
              ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            TextButton(
              onPressed: () async {
                if (!await confirm(
                      context,
                      '删除准备事项',
                      '删除“${original['name']}”？',
                    ) ||
                    !mounted) {
                  return;
                }
                try {
                  widget.store.savePreparations(
                    originalTrip,
                    widget.store
                        .preparations(originalTrip)
                        .where((p) => p['id'] != widget.id)
                        .toList(),
                  );
                  widget.onClose();
                } catch (e) {
                  setState(() => error = e.toString());
                }
              },
              child: const Text('删除'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () {
                if (save()) widget.onClose();
              },
              child: const Text('保存事项'),
            ),
          ],
        ),
      ),
    ],
  );
}
