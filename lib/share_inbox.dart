import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MapShareInbox extends ValueNotifier<Map<String, String>?> {
  MapShareInbox._() : super(null);
  static final instance = MapShareInbox._();
  static const channel = MethodChannel('howdoi/map_share');
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    await refresh();
  }

  Future<void> refresh() async {
    final result = await channel.invokeMapMethod<String, dynamic>('peek');
    value = result?['id'] == null || result?['text'] == null
        ? null
        : Map<String, String>.from(result!);
  }

  Future<void> acknowledge(String? id) async {
    if (id == null) return;
    await channel.invokeMethod<void>('ack', id);
    await refresh();
  }
}
