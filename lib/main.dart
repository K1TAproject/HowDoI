import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'store.dart';
import 'sync.dart';
import 'home.dart';
import 'app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final normalErrorHandler = FlutterError.onError;
  if (args.isNotEmpty && args.first.startsWith('--update-')) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      exit(1);
    };
  }
  tzdata.initializeTimeZones();
  try {
    if ((args.length == 3 || args.length == 4 && args[3] == '--window-test') &&
        args.first == '--update-probe') {
      final probe = Store(args[1]);
      // Force compatibility reads before reporting success; never enable synchronization.
      for (final trip in probe.trips) {
        probe.visibleDays(trip.id);
      }
      runApp(HowDoI(store: probe, sync: SyncService(probe, host: false)));
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await File(args[2]).writeAsString('ready', flush: true);
        // The native-window verification script uses only this isolated DB.
        // Normal updater probes still exit immediately after the first frame.
        if (args.length == 4) {
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        probe.dispose();
        exit(0);
      });
      return;
    }
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final store = Store('${directory.path}${Platform.pathSeparator}howdoi.db');
    final sync = SyncService(store, host: Platform.isWindows);
    runApp(HowDoI(store: store, sync: sync));
    if (args.length == 2 && args.first == '--update-ready') {
      final written = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await File(args[1]).writeAsString('ready', flush: true);
        written.complete();
      });
      // Wait for the old instance to acknowledge readiness and release its sync port.
      await written.future;
      while (await File(args[1]).exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      FlutterError.onError = normalErrorHandler;
    }
    await sync.restore();
  } catch (e) {
    if (args.isNotEmpty && args.first.startsWith('--update-')) exit(1);
    runApp(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText('本地数据未能打开。请保留数据目录，不要卸载应用。\n$e'),
            ),
          ),
        ),
      ),
    );
  }
}

class HowDoI extends StatelessWidget {
  final Store store;
  final SyncService sync;
  const HowDoI({super.key, required this.store, required this.sync});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HowDoI',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: appTheme(),
    home: Home(store: store, sync: sync),
  );
}
