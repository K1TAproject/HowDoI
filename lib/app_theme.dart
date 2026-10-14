import 'package:flutter/material.dart';

ThemeData appTheme() {
  const primary = Color(0xff8daed1);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: primary,
        onPrimary: const Color(0xff101b29),
        primaryContainer: const Color(0xff283b50),
        surface: const Color(0xff15191f),
        surfaceContainerLow: const Color(0xff191e25),
        surfaceContainer: const Color(0xff202630),
        surfaceContainerHigh: const Color(0xff29313c),
        onSurface: const Color(0xffe2e7ef),
        onSurfaceVariant: const Color(0xffaeb9c8),
        outline: const Color(0xff626f80),
        outlineVariant: const Color(0xff303a47),
        error: const Color(0xffffb4ab),
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xff101318),
    fontFamily: 'Microsoft YaHei',
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xff15191f),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: scheme.surfaceContainerLow),
    popupMenuTheme: PopupMenuThemeData(color: scheme.surfaceContainer),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: const Color(0xff354c67),
      foregroundColor: scheme.onSurface,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: scheme.onSurface,
      selectedTileColor: const Color(0xff283b50),
      iconColor: scheme.onSurfaceVariant,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(5),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? primary
            : const Color(0xff596675),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    focusColor: primary.withValues(alpha: .25),
    hoverColor: primary.withValues(alpha: .08),
    disabledColor: const Color(0xff85909f),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    timePickerTheme: TimePickerThemeData(backgroundColor: scheme.surface),
  );
}
