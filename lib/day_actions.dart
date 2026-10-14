import 'package:flutter/material.dart';
import 'editors.dart';
import 'model.dart';
import 'pickers.dart';
import 'planner.dart';
import 'store.dart';

Future<int?> changeTravelDay(
  BuildContext context,
  Store store,
  Record trip,
  int source, {
  required bool deleting,
  required VoidCallback onUndo,
}) async {
  final generation = store.generation;
  final primary = store.primaryItems(trip.id, source);
  final related = store.relatedItems(trip.id, source);
  if (deleting && primary.isEmpty && related.isEmpty) {
    store.changeDay(trip, source, expectedGeneration: generation);
    final removed = store.get('day:${trip.id}:$source')!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 7),
        content: Text('已删除 ${dayLabel(trip, source)}'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            try {
              store.undoEmptyDay(removed);
              onUndo();
            } catch (e) {
              notice(context, e);
            }
          },
        ),
      ),
    );
  } else {
    int? target;
    var deleteItems = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(
            '${deleting ? '删除' : '调整'}日期 · ${dayTitle(trip, source)}',
          ),
          content: SizedBox(
            width: 480,
            height: (MediaQuery.sizeOf(c).height - 240).clamp(200.0, 520.0),
            child: PickerRegion(
              child: ListView(
                children: [
                  Text('当天开始的行程：${primary.length} 条'),
                  for (final r in primary)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(itemTitle(r.data)),
                      subtitle: Text(
                        '${itemType(r.data)} · ${r.data['booking']}${r.data['endDay'] > source ? ' · 延续至第 ${r.data['endDay']} 天' : ''}',
                      ),
                    ),
                  if (related.isNotEmpty) ...[
                    const Divider(),
                    Text('其他日期开始的关联记录：${related.length} 条（保留原记录）'),
                    for (final r in related)
                      Text('• ${itemTitle(r.data)} · 第 ${r.data['day']} 天开始'),
                    Text(
                      deleting
                          ? '此日期仍承载住宿覆盖或跨日到达。请先在原行程中调整关联日期，再删除此日期。'
                          : '此日期仍承载住宿覆盖或跨日到达。本次仅移动当天开始的行程；关联原记录及其日期保留。',
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (deleting)
                    choice(
                      '处理方式',
                      deleteItems,
                      const [false, true],
                      (v) => set(() => deleteItems = v!),
                      name: (v) => v ? '删除当天行程及日期' : '将当天行程移到另一日后删除日期',
                    ),
                  if (!deleteItems)
                    PickField(
                      '目标日期',
                      target == null ? '' : dayLabel(trip, target!),
                      onTap: (anchor) async {
                        final value = await chooseDay(
                          anchor,
                          trip.data,
                          target ?? source,
                        );
                        if (value != null && c.mounted) {
                          set(() => target = value);
                        }
                      },
                      onClear: () => set(() => target = null),
                    ),
                  if (target == source && !deleteItems) const Text('请选择不同的日期。'),
                  if (!deleteItems &&
                      target != null &&
                      store.visibleDays(trip.id).contains(target))
                    Text(
                      '目标日期已有 ${store.primaryItems(trip.id, target!).length} 条行程；确认后合并，并沿用时间与手动排序规则。',
                    ),
                  const SizedBox(height: 8),
                  Text(
                    deleteItems
                        ? '仅删除以上当天开始的记录，其住宿覆盖/跨日显示也会一并移除；其他日期开始的关联记录不会删除。'
                        : '以上行程整体移动，结束旅行日按相同天数平移。已预订的票面日期保持不变，请逐条核对。其他旅行日及编号不变。',
                  ),
                  if (deleteItems && related.isNotEmpty)
                    const Text('请先调整关联记录，再删除此日期。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  (!(deleting && related.isNotEmpty) &&
                      (deleteItems
                          ? related.isEmpty
                          : target != null && target != source))
                  ? () => Navigator.pop(c, true)
                  : null,
              child: Text(deleteItems ? '继续删除…' : '确认移动'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !context.mounted) return null;
    if (deleteItems &&
        !await confirm(
          context,
          '再次确认删除 ${primary.length} 条行程',
          '${primary.map((r) => '• ${itemTitle(r.data)}').join('\n')}\n\n这些记录及其跨日显示将被删除并同步。其他日期开始的记录不受影响。',
        )) {
      return null;
    }
    store.changeDay(
      trip,
      source,
      target: deleteItems ? null : target,
      deleteItems: deleteItems,
      requireSourceRemoved: deleting,
      expectedGeneration: generation,
    );
    if (!deleting) return target;
  }
  final days = store.visibleDays(trip.id);
  return days.where((d) => d >= source).firstOrNull ?? days.lastOrNull ?? 0;
}
