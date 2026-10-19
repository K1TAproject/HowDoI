import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'model.dart';
import 'places.dart';
import 'planner.dart';
import 'maps.dart';

// A marker is a view of the original record, never a copied itinerary/budget.
class DayPoint {
  final int number;
  final MapVisit visit;
  final Map<String, dynamic> position;
  DayPoint(this.number, this.visit, this.position);
  LatLng get coordinate => LatLng(
    (position['lat'] as num).toDouble().clamp(-85.05112878, 85.05112878),
    (position['lon'] as num).toDouble(),
  );
}

List<MapVisit> dayVisits(List<PlanNode> nodes) => mapVisits(
  nodes,
  daily: true,
).where((v) => hasPlace(v.node.item.data, v.slot)).toList();
List<DayPoint> dayPoints(List<MapVisit> visits) => [
  for (var i = 0; i < visits.length; i++)
    if (!visits[i].stale &&
        currentPosition(
              locationBinding(visits[i].node.item.data, visits[i].slot),
            ) !=
            null)
      DayPoint(
        i + 1,
        visits[i],
        currentPosition(
          locationBinding(visits[i].node.item.data, visits[i].slot),
        )!,
      ),
];

class DayMap extends StatefulWidget {
  final List<PlanNode> nodes;
  final ValueChanged<Record> onItem;
  final TileProvider? tileProvider;
  const DayMap({
    super.key,
    required this.nodes,
    required this.onItem,
    this.tileProvider,
  });
  @override
  State<DayMap> createState() => _DayMapState();
}

class _DayMapState extends State<DayMap> {
  final controller = MapController();
  bool expanded = true, failed = false, ready = false;
  int revision = 0;
  Timer? timeout;
  NetworkTileProvider? provider;
  bool loaded = false;
  List<MapVisit> get visits => dayVisits(widget.nodes);
  List<DayPoint> get points => dayPoints(visits);
  String signature(List<PlanNode> nodes) => jsonEncode([
    for (final p in dayPoints(dayVisits(nodes)))
      [p.visit.node.item.id, p.visit.slot, p.position],
  ]);
  CameraFit fit(List<DayPoint> p) => CameraFit.bounds(
    bounds: LatLngBounds.fromPoints(p.map((e) => e.coordinate).toList()),
    padding: const EdgeInsets.all(40),
    maxZoom: 15,
  );
  void fitAll() {
    if (ready && points.isNotEmpty) controller.fitCamera(fit(points));
  }

  @override
  void didUpdateWidget(covariant DayMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (points.isEmpty) {
      timeout?.cancel();
      provider = null;
      ready = false;
      loaded = false;
      failed = false;
      revision++;
    }
    if (signature(oldWidget.nodes) != signature(widget.nodes)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fitAll();
      });
    }
  }

  void fail(int attempt) {
    scheduleMicrotask(() {
      if (mounted && !failed && expanded && revision == attempt) {
        timeout?.cancel();
        setState(() {
          provider = null;
          failed = true;
          ready = false;
        });
      }
    });
  }

  @override
  void dispose() {
    timeout?.cancel();
    controller.dispose();
    super.dispose();
  }

  String label(MapVisit v) =>
      locationBinding(v.node.item.data, v.slot)?['name'] ??
      placeText(v.node.item.data, v.slot);
  Future<void> showPoints(List<DayPoint> entries) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(
        entries.length == 1
            ? '地点 ${entries.first.number}'
            : '此处有 ${entries.length} 次到访',
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${p.number}. ${label(p.visit)}'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${itemTitle(p.visit.node.item.data)} · ${p.visit.node.time}',
                      ),
                      Wrap(
                        children: [
                          if (locationBinding(
                                p.visit.node.item.data,
                                p.visit.slot,
                              )?['url'] !=
                              null)
                            TextButton(
                              onPressed: () => openBoundPlace(
                                c,
                                locationBinding(
                                  p.visit.node.item.data,
                                  p.visit.slot,
                                )!,
                              ),
                              child: const Text('打开原地图'),
                            ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(c);
                              widget.onItem(p.visit.node.item);
                            },
                            child: const Text('编辑'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
  Future<void> completeMissing() async {
    final missing = visits
        .where(
          (v) =>
              v.stale ||
              currentPosition(locationBinding(v.node.item.data, v.slot)) ==
                  null,
        )
        .toList();
    if (missing.length == 1) {
      widget.onItem(missing.single.node.item);
      return;
    }
    final chosen = await showDialog<Record>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('补充或核对坐标'),
        children: [
          for (final v in missing)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, v.node.item),
              child: Text('${label(v)} · ${itemTitle(v.node.item.data)}'),
            ),
        ],
      ),
    );
    if (chosen != null && mounted) widget.onItem(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final all = visits, shown = points;
    final attempt = revision;
    if (all.isEmpty) return const SizedBox.shrink();
    final groups = <String, List<DayPoint>>{};
    for (final p in shown) {
      groups
          .putIfAbsent(
            '${p.coordinate.latitude},${p.coordinate.longitude}',
            () => [],
          )
          .add(p);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (shown.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() {
                  expanded = !expanded;
                  if (!expanded) {
                    timeout?.cancel();
                    ready = false;
                    provider = null;
                    loaded = false;
                    revision++;
                  }
                }),
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                label: const Text('当天地图'),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('已显示 ${shown.length}/${all.length} 个地点'),
            ),
            if (shown.length < all.length)
              TextButton(onPressed: completeMissing, child: const Text('补充坐标')),
          ],
        ),
        if (shown.isNotEmpty && expanded) ...[
          SizedBox(
            height: MediaQuery.sizeOf(context).width < 600 ? 230 : 280,
            child: failed
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('地图加载失败或超时，文字路书仍可使用。'),
                        TextButton(
                          onPressed: () => setState(() {
                            failed = false;
                            loaded = false;
                            provider = null;
                            revision++;
                          }),
                          child: const Text('重试地图'),
                        ),
                      ],
                    ),
                  )
                : FlutterMap(
                    key: ValueKey(revision),
                    mapController: controller,
                    options: MapOptions(
                      initialCameraFit: fit(shown),
                      minZoom: 1,
                      maxZoom: 19,
                      onMapReady: () {
                        scheduleMicrotask(() {
                          if (!mounted || attempt != revision) return;
                          setState(() => ready = true);
                          timeout?.cancel();
                          if (!loaded) {
                            timeout = Timer(
                              const Duration(seconds: 20),
                              () => fail(attempt),
                            );
                          }
                        });
                      },
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                    ),
                    children: [
                      TileLayer(
                        userAgentPackageName: 'com.k1taproject.howdoi',
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        panBuffer: 0,
                        keepBuffer: 0,
                        tileProvider:
                            widget.tileProvider ??
                            (provider ??= NetworkTileProvider(
                              headers: {
                                'User-Agent':
                                    'HowDoI (+https://github.com/K1TAproject/HowDoI)',
                              },
                              cachingProvider:
                                  BuiltInMapCachingProvider.getOrCreateInstance(
                                    maxCacheSize: 128 * 1024 * 1024,
                                  ),
                            )),
                        errorTileCallback: (_, _, _) => fail(attempt),
                        tileBuilder: (_, tile, image) {
                          if (image.loadFinishedAt != null &&
                              !image.loadError) {
                            loaded = true;
                            timeout?.cancel();
                          }
                          return tile;
                        },
                      ),
                      MarkerLayer(
                        markers: [
                          for (final group in groups.values)
                            Marker(
                              point: group.first.coordinate,
                              width: 48,
                              height: 48,
                              child: Tooltip(
                                message: group
                                    .map(
                                      (p) => '${p.number}. ${label(p.visit)}',
                                    )
                                    .join('\n'),
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    shape: const CircleBorder(),
                                  ),
                                  onPressed: () => showPoints(group),
                                  child: Text(
                                    group.length == 1
                                        ? '${group.first.number}'
                                        : '${group.first.number}+${group.length - 1}',
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: ColoredBox(
                          color: Colors.white,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.black,
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () => openMapUrl(
                              Uri.parse(
                                'https://www.openstreetmap.org/copyright',
                              ),
                            ),
                            child: const Text('© OpenStreetMap contributors'),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          Wrap(
            children: [
              TextButton(
                onPressed: ready ? fitAll : null,
                child: const Text('显示全部地点'),
              ),
              IconButton(
                tooltip: '放大地图',
                onPressed: ready
                    ? () => controller.move(
                        controller.camera.center,
                        (controller.camera.zoom + 1).clamp(1, 19),
                      )
                    : null,
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: '缩小地图',
                onPressed: ready
                    ? () => controller.move(
                        controller.camera.center,
                        (controller.camera.zoom - 1).clamp(1, 19),
                      )
                    : null,
                icon: const Icon(Icons.remove),
              ),
              TextButton(
                onPressed: () => showPoints(shown),
                child: const Text('查看标点列表'),
              ),
            ],
          ),
          if (shown.any((p) => (p.position['lat'] as num).abs() > 85.05112878))
            const Text('极区坐标按底图投影边界显示；保存的经纬度不变。'),
        ],
      ],
    );
  }
}
