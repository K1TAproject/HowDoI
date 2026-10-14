import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/pickers.dart';
import 'package:howdoi/app_theme.dart';

class Harness extends StatefulWidget {
  final bool date, duration;
  final String initial;
  const Harness({
    super.key,
    this.date = false,
    this.duration = false,
    this.initial = '',
  });
  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  late String value = widget.initial;
  double height = 460;
  void resize(double value) => setState(() => height = value);
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: appTheme(),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh', 'CN')],
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: 320,
          height: height,
          child: PickerRegion(
            key: const ValueKey('region'),
            child: ListView(
              controller: scroll,
              children: [
                const SizedBox(height: 40),
                PickField(
                  '字段',
                  value,
                  onTap: (c) async {
                    final next = widget.date
                        ? await calendarDate(c, value, fallback: '2030-04-12')
                        : await clockValue(c, value, duration: widget.duration);
                    if (next != null && mounted) setState(() => value = next);
                  },
                  onClear: () => setState(() => value = ''),
                ),
                const SizedBox(height: 700),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'empty clock cancellation is inert; arbitrary minute, arrows and duration survive',
    (t) async {
      final key = GlobalKey<HarnessState>();
      await t.pumpWidget(Harness(key: key));
      await t.tap(find.byTooltip('选择字段'));
      await t.pumpAndSettle();
      expect(key.currentState!.value, '');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(key.currentState!.value, '');
      await t.pumpWidget(const SizedBox());
      final clock = GlobalKey<HarnessState>();
      await t.pumpWidget(Harness(key: clock, initial: '09:37'));
      await t.tap(find.byTooltip('选择字段'));
      await t.pumpAndSettle();
      await t.tap(find.text('38'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      expect(clock.currentState!.value, '09:37');
      await t.tap(find.byTooltip('选择字段'));
      await t.pumpAndSettle();
      await t.tap(find.text('38'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(clock.currentState!.value, '09:37');
      await t.pumpWidget(const SizedBox());
      final duration = GlobalKey<HarnessState>();
      await t.pumpWidget(
        Harness(key: duration, initial: '18377', duration: true),
      );
      await t.tap(find.byTooltip('选择字段'));
      await t.pumpAndSettle();
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      expect(duration.currentState!.value, '18377');
      expect(t.takeException(), isNull);
    },
  );
  for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
    testWidgets(
      'date stays inside editor at scale $dpr, writes immediately and dismisses on scroll/resize',
      (t) async {
        t.view.physicalSize = Size(900 * dpr, 720 * dpr);
        t.view.devicePixelRatio = dpr;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final key = GlobalKey<HarnessState>();
        await t.pumpWidget(Harness(key: key, date: true));
        await t.tap(find.text('点击选择（可留空）'));
        await t.pumpAndSettle();
        expect(
          t
              .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
              .initialDate,
          DateTime(2030, 4, 12),
        );
        final popup = t.getRect(find.byKey(const ValueKey('field-picker')));
        final region = t.getRect(find.byKey(const ValueKey('region')));
        expect(region.contains(popup.topLeft), true);
        expect(region.contains(popup.bottomRight), true);
        await t.tap(find.text('15').last);
        await t.pumpAndSettle();
        expect(key.currentState!.value, '2030-04-15');
        expect(find.byKey(const ValueKey('field-picker')), findsNothing);
        await t.tap(find.byTooltip('选择字段'));
        await t.pumpAndSettle();
        key.currentState!.scroll.jumpTo(15);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('field-picker')), findsNothing);
        await t.tap(find.byTooltip('选择字段'));
        await t.pumpAndSettle();
        key.currentState!.resize(280);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('field-picker')), findsNothing);
        await t.tap(find.byTooltip('选择字段'));
        await t.pumpAndSettle();
        final compact = t.getRect(find.byKey(const ValueKey('field-picker')));
        expect(
          t
              .getRect(find.byKey(const ValueKey('region')))
              .contains(compact.bottomRight),
          true,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
}
