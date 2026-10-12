import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'store.dart';
import 'sync.dart';
import 'home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  try {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final store = Store('${directory.path}${Platform.pathSeparator}howdoi.db');
    final sync = SyncService(store, host: Platform.isWindows);
    runApp(HowDoI(store: store, sync: sync));
    await sync.restore();
  } catch (e) {
    runApp(
      MaterialApp(
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
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b68)),
      scaffoldBackgroundColor: const Color(0xfff6f8f7),
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
    ),
    home: Home(store: store, sync: sync),
  );
}
