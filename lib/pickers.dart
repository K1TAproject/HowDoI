import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'model.dart';

// A bounded editor-local overlay. It never covers the editor's save/close row.
class PickerRegion extends StatefulWidget {
  final Widget child;
  final bool handleBack;
  const PickerRegion({super.key, required this.child, this.handleBack = true});
  @override
  State<PickerRegion> createState() => PickerRegionState();
}

class PickerRegionState extends State<PickerRegion>
    with WidgetsBindingObserver {
  final region = GlobalKey();
  Completer<Object?>? pending;
  Widget? panel;
  Rect anchor = Rect.zero;
  double height = 400;
  Size? previousSize;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pending?.complete(null);
    super.dispose();
  }

  void close([Object? value]) {
    pending?.complete(value);
    pending = null;
    if (mounted && panel != null) setState(() => panel = null);
  }

  bool dismissIfOpen() {
    if (panel == null) return false;
    close();
    return true;
  }

  @override
  void didChangeMetrics() => close();
  Future<Object?> open(
    BuildContext field,
    Widget Function(ValueChanged<Object?>) builder,
    double desiredHeight,
  ) {
    close();
    final box = region.currentContext!.findRenderObject() as RenderBox;
    final target = field.findRenderObject() as RenderBox;
    anchor = target.localToGlobal(Offset.zero, ancestor: box) & target.size;
    height = desiredHeight;
    final result = pending = Completer<Object?>();
    setState(() => panel = builder(close));
    return result.future;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (previousSize != null && previousSize != size && panel != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => close());
      }
      previousSize = size;
      final width = math.min(360.0, math.max(0.0, size.width - 16));
      final popupHeight = math.min(height, math.max(0.0, size.height - 16));
      final left = anchor.left.clamp(
        8.0,
        math.max(8.0, size.width - width - 8),
      );
      final below = anchor.bottom + 4;
      final top =
          (below + popupHeight <= size.height - 8
                  ? below
                  : anchor.top - popupHeight - 4)
              .clamp(8.0, math.max(8.0, size.height - popupHeight - 8));
      return PopScope(
        canPop: !widget.handleBack || panel == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.handleBack) close();
        },
        child: Stack(
          key: region,
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (panel != null &&
                      (n is ScrollStartNotification ||
                          n is ScrollUpdateNotification)) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => close(),
                    );
                  }
                  return false;
                },
                child: widget.child,
              ),
            ),
            if (panel != null) ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: close,
                ),
              ),
              Positioned(
                left: left.toDouble(),
                top: top.toDouble(),
                width: width,
                height: popupHeight,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): close,
                  },
                  child: Focus(
                    autofocus: true,
                    child: Material(
                      key: const ValueKey('field-picker'),
                      elevation: 4,
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: SingleChildScrollView(child: panel),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

Future<T?> _open<T>(
  BuildContext context,
  Widget Function(ValueChanged<T?>) builder,
  double height,
) async {
  final region = context.findAncestorStateOfType<PickerRegionState>();
  if (region != null) {
    return await region.open(context, (close) => builder(close), height) as T?;
  }
  return showDialog<T>(
    context: context,
    builder: (c) => AlertDialog(
      contentPadding: const EdgeInsets.all(8),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: builder((v) => Navigator.pop(c, v)),
        ),
      ),
    ),
  );
}

Future<String?> calendarDate(
  BuildContext context,
  String current, {
  String fallback = '',
  DateTime? first,
  DateTime? last,
}) {
  final from = first ?? DateTime(1900), to = last ?? DateTime(2200, 12, 31);
  var initial = parseDate(current) ?? parseDate(fallback) ?? DateTime.now();
  if (initial.isBefore(from)) initial = from;
  if (initial.isAfter(to)) initial = to;
  return _open<String>(
    context,
    (close) => _Calendar(initial: initial, first: from, last: to, close: close),
    422,
  );
}

class _Calendar extends StatefulWidget {
  final DateTime initial, first, last;
  final ValueChanged<String?> close;
  const _Calendar({
    required this.initial,
    required this.first,
    required this.last,
    required this.close,
  });
  @override
  State<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends State<_Calendar> {
  late DateTime displayed = widget.initial;
  int revision = 0;
  bool choosingMonth = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      children: [
        Row(
          children: [
            const Expanded(child: Text('选择日期 · 点击年份可快速切换')),
            TextButton(
              onPressed: () => setState(() => choosingMonth = !choosingMonth),
              child: Text('${displayed.month}月 ▾'),
            ),
          ],
        ),
        SizedBox(
          height: 300,
          child: choosingMonth
              ? GridView.count(
                  crossAxisCount: 3,
                  childAspectRatio: 2,
                  children: List.generate(12, (i) {
                    final end = DateTime(displayed.year, i + 2, 0),
                        start = DateTime(displayed.year, i + 1);
                    return TextButton(
                      onPressed:
                          end.isBefore(widget.first) ||
                              start.isAfter(widget.last)
                          ? null
                          : () => setState(() {
                              displayed = DateTime(displayed.year, i + 1);
                              if (displayed.isBefore(widget.first)) {
                                displayed = widget.first;
                              }
                              revision++;
                              choosingMonth = false;
                            }),
                      child: Text('${i + 1}月'),
                    );
                  }),
                )
              : CalendarDatePicker(
                  key: ValueKey(revision),
                  initialDate: displayed,
                  firstDate: widget.first,
                  lastDate: widget.last,
                  onDisplayedMonthChanged: (v) => setState(() => displayed = v),
                  onDateChanged: (v) => widget.close(dateText(v)),
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => widget.close(null),
            child: const Text('取消'),
          ),
        ),
      ],
    ),
  );
}

Future<String?> clockValue(
  BuildContext context,
  String current, {
  bool duration = false,
}) => _open<String>(
  context,
  (close) => _Clock(current: current, duration: duration, close: close),
  332,
);

class _Clock extends StatefulWidget {
  final String current;
  final bool duration;
  final ValueChanged<String?> close;
  const _Clock({
    required this.current,
    required this.duration,
    required this.close,
  });
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late int hour, minute;
  @override
  void initState() {
    super.initState();
    final parts = widget.current.split(':');
    final total = math.max(0, int.tryParse(widget.current) ?? 0);
    hour = widget.duration
        ? total ~/ 60
        : (int.tryParse(parts.first) ?? 0).clamp(0, 23);
    minute = widget.duration
        ? total % 60
        : (parts.length == 2 ? int.tryParse(parts.last) ?? 0 : 0).clamp(0, 59);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        Text(widget.duration ? '预计时长 · 可超过 24 小时' : '选择时间 · 24 小时制'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _NumberColumn(
                label: '小时',
                count: widget.duration ? math.max(169, hour + 1) : 24,
                value: hour,
                onChanged: (v) => setState(() => hour = v),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _NumberColumn(
                label: '分钟',
                count: 60,
                value: minute,
                onChanged: (v) => setState(() => minute = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => widget.close(null),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.close(
                widget.duration
                    ? '${hour * 60 + minute}'
                    : '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
              ),
              child: const Text('完成'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _NumberColumn extends StatefulWidget {
  final String label;
  final int count, value;
  final ValueChanged<int> onChanged;
  const _NumberColumn({
    required this.label,
    required this.count,
    required this.value,
    required this.onChanged,
  });
  @override
  State<_NumberColumn> createState() => _NumberColumnState();
}

class _NumberColumnState extends State<_NumberColumn> {
  late final controller = ScrollController(
    initialScrollOffset: ((widget.value - 2) * 36.0).clamp(
      0.0,
      math.max(0.0, widget.count * 36 - 180),
    ),
  );
  final focus = FocusNode();
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(widget.label),
      const SizedBox(height: 4),
      Focus(
        focusNode: focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (_, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          final delta = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? 1
              : event.logicalKey == LogicalKeyboardKey.arrowUp
              ? -1
              : 0;
          if (delta == 0) return KeyEventResult.ignored;
          final next = (widget.value + delta).clamp(0, widget.count - 1);
          widget.onChanged(next);
          controller.jumpTo(
            ((next - 2) * 36.0).clamp(0.0, controller.position.maxScrollExtent),
          );
          return KeyEventResult.handled;
        },
        child: Container(
          height: 184,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focus.hasFocus
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Scrollbar(
            controller: controller,
            thumbVisibility: true,
            child: ListView.builder(
              controller: controller,
              itemExtent: 36,
              itemCount: widget.count,
              itemBuilder: (context, i) => Material(
                color: widget.value == i
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Colors.transparent,
                child: InkWell(
                  canRequestFocus: false,
                  onTap: () {
                    focus.requestFocus();
                    widget.onChanged(i);
                  },
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(i.toString().padLeft(2, '0')),
                        if (widget.value == i)
                          const Icon(Icons.check, size: 16),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

Future<int?> chooseDay(
  BuildContext context,
  Map<String, dynamic> trip,
  int current, {
  String existing = '',
}) async {
  final start = parseDate(trip['start'] ?? '');
  if (start != null) {
    final value = await calendarDate(
      context,
      existing,
      fallback: dayDate(trip, current > 0 ? current : 1),
      first: start,
      last: DateTime(start.year, start.month, start.day + 3659),
    );
    if (value == null) return null;
    final selected = parseDate(value)!;
    return DateTime.utc(
          selected.year,
          selected.month,
          selected.day,
        ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
        1;
  }
  return _open<int>(
    context,
    (close) => _DayList(current: current, close: close),
    372,
  );
}

class _DayList extends StatefulWidget {
  final int current;
  final ValueChanged<int?> close;
  const _DayList({required this.current, required this.close});
  @override
  State<_DayList> createState() => _DayListState();
}

class _DayListState extends State<_DayList> {
  late final controller = ScrollController(
    initialScrollOffset: ((widget.current.clamp(1, 3660) - 1) * 48.0).clamp(
      0.0,
      3660 * 48.0 - 300,
    ),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('选择旅行日'),
      SizedBox(
        height: 300,
        child: ListView.builder(
          controller: controller,
          itemExtent: 48,
          itemCount: 3660,
          itemBuilder: (_, i) => ListTile(
            title: Text('第 ${i + 1} 天'),
            selected: widget.current == i + 1,
            onTap: () => widget.close(i + 1),
          ),
        ),
      ),
      TextButton(onPressed: () => widget.close(null), child: const Text('取消')),
    ],
  );
}

class PickField extends StatefulWidget {
  final String label, value;
  final ValueChanged<BuildContext> onTap;
  final VoidCallback onClear;
  const PickField(
    this.label,
    this.value, {
    super.key,
    required this.onTap,
    required this.onClear,
  });
  @override
  State<PickField> createState() => _PickFieldState();
}

class _PickFieldState extends State<PickField> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onTap(anchor),
        onFocusChange: (v) => setState(() => focused = v),
        child: InputDecorator(
          isFocused: focused,
          decoration: InputDecoration(labelText: widget.label, isDense: true),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    widget.value.isEmpty ? '点击选择（可留空）' : widget.value,
                  ),
                ),
              ),
              if (widget.value.isNotEmpty)
                IconButton(
                  tooltip: '清除${widget.label}',
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(24, 32),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: widget.onClear,
                  icon: const Icon(Icons.close, size: 18),
                ),
              IconButton(
                tooltip: '选择${widget.label}',
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(24, 32),
                ),
                constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: () => widget.onTap(anchor),
                icon: const Icon(Icons.expand_more),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
