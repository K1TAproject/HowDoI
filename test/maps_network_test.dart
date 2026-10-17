import 'dart:io';
import 'dart:async';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/io_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howdoi/places.dart';
import 'package:howdoi/store.dart';

void main() {
  test('opt-in real tile provider decoding and cache', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cache = BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: Directory('work/map-provider-test-cache').absolute.path,
    );
    final client = IOClient(
      _DirectHttp().createHttpClient(null)
        ..connectionTimeout = const Duration(seconds: 10),
    );
    final provider = NetworkTileProvider(
      headers: {'User-Agent': mapAgent},
      httpClient: client,
      cachingProvider: cache,
    );
    try {
      final image = provider.getImageWithCancelLoadingSupport(
        const TileCoordinates(58211, 25808, 16),
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        ),
        Completer<void>().future,
      );
      final done = Completer<ImageInfo>();
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) {
          if (!done.isCompleted) done.complete(info);
        },
        onError: (Object e, StackTrace? s) {
          if (!done.isCompleted) done.completeError(e, s);
        },
      );
      stream.addListener(listener);
      try {
        final info = await done.future.timeout(const Duration(seconds: 25));
        expect(info.image.width, 256);
        expect(info.image.height, 256);
      } finally {
        stream.removeListener(listener);
      }
      // ignore: avoid_print
      print('Actual NetworkTileProvider decoded official OSM 256 x 256 tile.');
    } finally {
      client.close();
      await cache.destroy();
    }
  }, skip: !const bool.fromEnvironment('HOWDOI_MAP_NETWORK'));
  test(
    'opt-in real network search through production client; independent data',
    () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _DirectHttp();
      final store = Store('work/map-network-test.db');
      try {
        for (final query in [
          'Beijing Capital International Airport',
          'Tokyo Station Japan',
          'Eiffel Tower Paris',
        ]) {
          final watch = Stopwatch()..start();
          try {
            final results = await PlaceSearch(store).search(query);
            // This is an actual request, or the persistent policy-required cache.
            // ignore: avoid_print
            print(
              '$query: ${results.length} candidates, ${watch.elapsedMilliseconds} ms',
            );
            expect(results, isNotEmpty);
          } catch (e) {
            // ignore: avoid_print
            print('$query: ${e.runtimeType}');
            rethrow;
          }
        }
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        try {
          final request = await client.getUrl(
            Uri.parse('https://tile.openstreetmap.org/0/0/0.png'),
          );
          request.headers.set(HttpHeaders.userAgentHeader, mapAgent);
          final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
          expect(response.statusCode, 200);
          await response.drain<void>();
          // ignore: avoid_print
          print('OSM sample tile: HTTP 200');
        } finally {
          client.close(force: true);
        }
      } finally {
        store.dispose();
        HttpOverrides.global = previousHttp;
      }
    },
    skip: !const bool.fromEnvironment('HOWDOI_MAP_NETWORK'),
  );
}

class _DirectHttp extends HttpOverrides {}
