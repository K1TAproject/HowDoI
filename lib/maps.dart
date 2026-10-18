import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'model.dart';
import 'places.dart';
import 'planner.dart';
import 'store.dart';

Future<bool> openMapUrl(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class PlaceMap extends StatefulWidget {
  final List<Map<String, dynamic>> points;
  final ValueChanged<int>? onPoint;
  final ValueChanged<LatLng>? onPick;
  final List<bool?> connections;
  const PlaceMap({
    super.key,
    required this.points,
    this.onPoint,
    this.onPick,
    this.connections = const [],
  });
  @override
  State<PlaceMap> createState() => _PlaceMapState();
}

class _PlaceMapState extends State<PlaceMap> {
  final controller = MapController();
  late final tileClient = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 4,
  );
  late final tileProvider = NetworkTileProvider(
    headers: {'User-Agent': mapAgent},
    httpClient: tileClient,
    cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
      maxCacheSize: 100 * 1024 * 1024,
    ),
  );
  bool failed = false;
  int attempt = 0;
  bool loaded = false, ready = false;
  Size? mapSize;
  Timer? loadTimer;
  void startTimer() {
    loadTimer?.cancel();
    loadTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && !loaded) setState(() => failed = true);
    });
  }

  @override
  void initState() {
    super.initState();
    startTimer();
  }

  List<LatLng> get points => widget.points
      .map(
        (p) =>
            LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
      )
      .toList();
  void fit() {
    if (points.isEmpty) return;
    if (points.length == 1) {
      controller.move(points.first, 14);
      return;
    }
    controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(40),
        maxZoom: 16,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant PlaceMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.points.toString() != widget.points.toString() &&
        !(widget.onPick != null &&
            widget.points.isNotEmpty &&
            widget.points.last['provider'] == 'manual')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fit();
      });
    }
  }

  @override
  void dispose() {
    loadTimer?.cancel();
    tileClient.close();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (mapSize != constraints.biggest) {
        mapSize = constraints.biggest;
        if (ready) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) fit();
          });
        }
      }
      return Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: controller,
                    options: MapOptions(
                      initialCenter: points.isEmpty
                          ? const LatLng(30, 110)
                          : points.first,
                      initialZoom: points.isEmpty ? 2 : 14,
                      initialCameraFit: points.length < 2
                          ? null
                          : CameraFit.bounds(
                              bounds: LatLngBounds.fromPoints(points),
                              padding: const EdgeInsets.all(40),
                              maxZoom: 16,
                            ),
                      minZoom: 1,
                      maxZoom: 19,
                      backgroundColor: const Color(0xff202630),
                      onMapReady: () {
                        ready = true;
                      },
                      onTap: (_, point) => widget.onPick?.call(point),
                    ),
                    children: [
                      TileLayer(
                        key: ValueKey(attempt),
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: mapAgent,
                        panBuffer: 0,
                        tileProvider: tileProvider,
                        tileBuilder: (context, child, tile) {
                          if (!loaded && tile.imageInfo != null) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && !loaded) {
                                setState(() {
                                  loaded = true;
                                  loadTimer?.cancel();
                                });
                              }
                            });
                          }
                          return child;
                        },
                        errorTileCallback: (_, _, _) {
                          if (!failed) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() => failed = true);
                            });
                          }
                        },
                      ),
                      if (widget.connections.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            for (var i = 1; i < points.length; i++)
                              if (widget.connections[i - 1] != null)
                                Polyline(
                                  points: [points[i - 1], points[i]],
                                  strokeWidth: 3,
                                  color: widget.connections[i - 1] == true
                                      ? Colors.blue.shade800
                                      : Colors.blueGrey.shade700,
                                  pattern: widget.connections[i - 1] == true
                                      ? const StrokePattern.solid()
                                      : StrokePattern.dashed(segments: [6, 8]),
                                ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          for (var i = 0; i < points.length; i++)
                            Marker(
                              point: points[i],
                              width: 44,
                              height: 44,
                              child: Tooltip(
                                message: widget.points[i]['name'] as String,
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                  ),
                                  onPressed: () => widget.onPoint?.call(i),
                                  child: Text('${i + 1}'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Card(
                      child: Column(
                        children: [
                          IconButton(
                            tooltip: '放大',
                            onPressed: () => controller.move(
                              controller.camera.center,
                              (controller.camera.zoom + 1).clamp(1, 19),
                            ),
                            icon: const Icon(Icons.add),
                          ),
                          IconButton(
                            tooltip: '缩小',
                            onPressed: () => controller.move(
                              controller.camera.center,
                              (controller.camera.zoom - 1).clamp(1, 19),
                            ),
                            icon: const Icon(Icons.remove),
                          ),
                          IconButton(
                            tooltip: '显示全部地点',
                            onPressed: fit,
                            icon: const Icon(Icons.fit_screen),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!loaded && !failed) const Text('地图加载中…文字行程仍可用'),
          if (failed)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('地图加载失败，文字行程仍可用。'),
                TextButton(
                  onPressed: () => setState(() {
                    failed = false;
                    attempt++;
                    loaded = false;
                    startTimer();
                  }),
                  child: const Text('重试'),
                ),
              ],
            ),
          TextButton(
            onPressed: () => openMapUrl(
              Uri.parse('https://www.openstreetmap.org/copyright'),
            ),
            child: const Text(
              '© OpenStreetMap contributors · ODbL',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      );
    },
  );
}

class TripMap extends StatelessWidget {
  final List<PlanNode> nodes;
  final ValueChanged<Record> onItem;
  final bool daily;
  const TripMap({
    super.key,
    required this.nodes,
    required this.onItem,
    this.daily = false,
  });
  @override
  Widget build(BuildContext context) {
    final visits = mapVisits(nodes, daily: daily);
    final located = visits.where((v) => v.place != null && !v.stale).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!daily) const Text('行程顺序，非实际道路路线。实线：已记录交通起终点；虚线：到访先后。不计算交通耗时。'),
        if (located.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('尚无已确认位置；请在行程详情中关联地点。'),
          )
        else
          SizedBox(
            height: daily
                ? (MediaQuery.sizeOf(context).width < 700 ? 260 : 320)
                : 360,
            child: PlaceMap(
              points: located.map((v) => v.place!).toList(),
              connections: daily
                  ? const []
                  : [
                      for (var i = 1; i < located.length; i++)
                        located[i - 1].node.day == 0 || located[i].node.day == 0
                            ? null
                            : located[i - 1].node.item.id ==
                                      located[i].node.item.id &&
                                  located[i - 1].slot == 'origin' &&
                                  located[i].slot == 'destination',
                    ],
              onPoint: (i) => showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text(located[i].label),
                  content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var j = 0; j < located.length; j++)
                            if (located[j].place!['lat'] ==
                                    located[i].place!['lat'] &&
                                located[j].place!['lon'] ==
                                    located[i].place!['lon'])
                              ListTile(
                                title: Text(
                                  '${j + 1}. ${itemTitle(located[j].node.item.data)}',
                                ),
                                subtitle: Text(
                                  '${located[j].node.time} · ${located[j].label}\n${located[j].place!['address']}',
                                ),
                                trailing: const Icon(Icons.edit_outlined),
                                onTap: () {
                                  Navigator.pop(c);
                                  onItem(located[j].node.item);
                                },
                              ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (located.isNotEmpty)
          ExpansionTile(
            key: PageStorageKey('map-place-list:$daily'),
            title: Text('地点与行程 · ${located.length}'),
            children: [
              for (var i = 0; i < located.length; i++)
                ListTile(
                  title: Text('${i + 1}. ${located[i].label}'),
                  subtitle: Text(
                    '${located[i].node.day == 0 ? '历史未安排' : '第 ${located[i].node.day} 天'} · ${located[i].node.time} · ${located[i].slot == 'origin'
                        ? '交通起点'
                        : located[i].slot == 'destination'
                        ? '交通终点'
                        : '地点'}',
                  ),
                  onTap: () => onItem(located[i].node.item),
                ),
            ],
          ),
        if (visits.any((v) => v.place == null || v.stale))
          ExpansionTile(
            key: PageStorageKey('map-missing-list:$daily'),
            title: Text(
              '尚未关联地点 / 待核对 · ${visits.where((v) => v.place == null || v.stale).length}',
            ),
            children: [
              for (final v in visits.where((v) => v.place == null || v.stale))
                ListTile(
                  title: Text(
                    '${v.stale ? '文字已变更，请核对位置' : '尚未关联地点'} · ${v.label.isEmpty ? itemTitle(v.node.item.data) : v.label}',
                  ),
                  trailing: const Icon(Icons.edit_location_alt_outlined),
                  onTap: () => onItem(v.node.item),
                ),
            ],
          ),
      ],
    );
  }
}

Future<Map<String, dynamic>?> choosePlace(
  BuildContext context,
  Store store,
  String text,
  Map<String, dynamic>? current,
) => Navigator.of(context).push<Map<String, dynamic>>(
  MaterialPageRoute(
    builder: (_) => _PlacePicker(store: store, text: text, current: current),
  ),
);

class _PlacePicker extends StatefulWidget {
  final Store store;
  final String text;
  final Map<String, dynamic>? current;
  const _PlacePicker({required this.store, required this.text, this.current});
  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  late final query = TextEditingController(text: widget.text);
  final region = TextEditingController();
  late final endpoint = TextEditingController(
    text: widget.store.setting('mapSearchEndpoint') ?? searchEndpoint,
  );
  List<Map<String, dynamic>> results = [];
  late Map<String, dynamic>? selected = widget.current;
  bool busy = false;
  String? error;
  bool searched = false;
  @override
  void dispose() {
    query.dispose();
    region.dispose();
    endpoint.dispose();
    super.dispose();
  }

  Future<void> search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found = await PlaceSearch(
        widget.store,
      ).search('${query.text.trim()} ${region.text.trim()}');
      if (mounted) {
        setState(() {
          results = found;
          searched = true;
        });
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on TimeoutException {
      if (mounted) setState(() => error = '搜索请求超时，请检查网络后重试；输入和原地点已保留。');
    } on SocketException {
      if (mounted) {
        setState(() => error = '无法连接搜索服务，请检查网络或代理后重试。与是否安装 Google Maps 无关。');
      }
    } catch (_) {
      if (mounted) setState(() => error = '搜索响应或连接异常，请稍后重试；输入和原地点已保留。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('选择地点')),
    body: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('仅地点关键词会发送到搜索服务。不要输入私人住址或机密信息。请选择正确候选，或在地图上点击选点。'),
              const SizedBox(height: 16),
              TextField(
                controller: query,
                decoration: const InputDecoration(labelText: '地点名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: region,
                decoration: const InputDecoration(labelText: '城市 / 地区（可选）'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
                onPressed: busy ? null : search,
                child: Text(
                  busy
                      ? '搜索中…'
                      : error != null
                      ? '重试搜索'
                      : '搜索',
                ),
              ),
              const Text(
                '个人双端使用：公共搜索两端合计最多每秒 1 次。请勿同时在电脑和手机搜索；本机请求间隔至少 3 秒并缓存。',
              ),
              TextButton(
                onPressed: () => openMapUrl(
                  Uri.parse(
                    'https://operations.osmfoundation.org/policies/nominatim/',
                  ),
                ),
                child: const Text('Nominatim 使用政策：点击搜索、限流、缓存，无自动补全'),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (searched && results.isEmpty)
                const Text('未找到候选。请补充城市或在地图上选点。'),
              if (results.isNotEmpty) const Text('请选择候选，尚未自动绑定任何搜索结果'),
              if (results.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in results)
                        ListTile(
                          selected: identical(selected, p),
                          title: Text(p['name']),
                          subtitle: Text(p['address']),
                          trailing: identical(selected, p)
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () {
                            FocusScope.of(context).unfocus();
                            setState(() => selected = p);
                          },
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text('地图底图文字不是可点击地点。移动、缩放后点击地图，将标记放到你确认的位置。'),
              SizedBox(
                height: 340,
                child: PlaceMap(
                  points: selected == null ? [] : [selected!],
                  onPick: (point) => setState(() {
                    selected = {
                      'name': query.text.trim().isEmpty
                          ? '手动选点'
                          : query.text.trim(),
                      'address': region.text.trim(),
                      'lat': point.latitude,
                      'lon': point.longitude,
                      'provider': 'manual',
                      'crs': 'WGS84',
                      'id': '',
                      'sourceText': '',
                      'country': '',
                    };
                  }),
                ),
              ),
              if (selected != null)
                Text(
                  '待确认标记：${selected!['name']} · ${selected!['address']}（${selected!['provider'] == 'manual' ? '手动选点，未识别底图地点身份' : '搜索候选'}）',
                ),
              ExpansionTile(
                title: const Text('搜索服务设置'),
                children: [
                  const Text(
                    '只更换兼容 Nominatim 的 HTTPS 搜索端点。不会随旅行同步或备份；使用前自行确认服务条款，不填写密钥。',
                  ),
                  TextField(
                    controller: endpoint,
                    decoration: const InputDecoration(labelText: '搜索端点'),
                  ),
                  TextButton(
                    onPressed: () {
                      final uri = Uri.tryParse(endpoint.text.trim());
                      if (uri == null ||
                          uri.scheme != 'https' ||
                          uri.host.isEmpty ||
                          uri.userInfo.isNotEmpty ||
                          uri.hasQuery ||
                          uri.hasFragment) {
                        setState(() => error = '请填写不含凭据、查询参数或片段的 HTTPS 地址');
                        return;
                      }
                      widget.store.setSetting(
                        'mapSearchEndpoint',
                        uri.toString(),
                      );
                      setState(() => error = null);
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('搜索端点已保存')));
                    },
                    child: const Text('保存端点'),
                  ),
                ],
              ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('仅写入草稿；还需保存行程才能同步。', textAlign: TextAlign.center),
                FilledButton(
                  onPressed: selected == null || busy
                      ? null
                      : () => Navigator.pop(context, {
                          ...selected!,
                          'sourceText': widget.text,
                        }),
                  child: const Text('确认地点'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> navigatePlace(
  BuildContext context,
  Store store,
  Map<String, dynamic> d, {
  String? slot,
  bool options = false,
}) async {
  final target = slot ?? (isTransport(d['type']) ? 'destination' : 'place');
  final p = placeStale(d, target) ? null : linkedPlace(d, target);
  var region = p?['country'] == 'cn'
      ? 'domestic'
      : p?['country'] != null && p!['country'] != ''
      ? 'overseas'
      : store.setting('mapRegion') ?? 'domestic';
  var provider =
      store.setting('mapProvider:$region') ??
      (region == 'domestic' ? 'baidu' : 'google');
  String? message;
  if (!hasPlace(d, target)) return;
  if (!options &&
      (p?['country'] == 'cn' ||
          (p?['country'] is String && p!['country'] != '') ||
          store.setting('mapRegion') != null)) {
    if (p == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在搜索文字地点，请在地图中确认结果。')));
    }
    final ok = await openMapUrl(navigationUri(provider, d, target));
    if (!context.mounted) return;
    if (ok) {
      store.setSetting('mapRegion', region);
      store.setSetting('mapProvider:$region', provider);
      return;
    }
    message = '无法打开地图。请尝试网页搜索，或复制地址。';
  }
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> launch({bool route = false, bool web = false}) async {
          store.setSetting('mapRegion', region);
          store.setSetting('mapProvider:$region', provider);
          final ok = await openMapUrl(
            navigationUri(provider, d, target, route: route, web: web),
          );
          if (c.mounted) {
            set(
              () => message = ok
                  ? '已请求外部地图打开，请在地图中确认目的地与出行方式。'
                  : '无法打开地图。请尝试网页搜索，或复制地址。',
            );
          }
        }

        return AlertDialog(
          title: const Text('外部地图'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  placeText(d, target).isEmpty
                      ? (p?['name'] ?? '未填写地点')
                      : placeText(d, target),
                ),
                if (p == null || placeStale(d, target))
                  const Text('当前使用文字搜索，请在地图中确认地点；不代表已准确定位。'),
                const Text('当前位置由外部地图获取。百度已关联点使用驾车导航，可在外部地图调整方式。'),
                DropdownButtonFormField<String>(
                  initialValue: region,
                  items: const [
                    DropdownMenuItem(value: 'domestic', child: Text('中国境内')),
                    DropdownMenuItem(value: 'overseas', child: Text('海外')),
                  ],
                  onChanged: (v) => set(() {
                    region = v!;
                    provider =
                        store.setting('mapProvider:$region') ??
                        (region == 'domestic' ? 'baidu' : 'google');
                  }),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('$region:$provider'),
                  initialValue: provider,
                  items: const [
                    DropdownMenuItem(value: 'baidu', child: Text('百度地图')),
                    DropdownMenuItem(
                      value: 'google',
                      child: Text('Google Maps'),
                    ),
                  ],
                  onChanged: (v) => set(() => provider = v!),
                ),
                if (message != null) Text(message!),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () {
                        store.setSetting('mapRegion', region);
                        store.setSetting('mapProvider:$region', provider);
                        set(() => message = '地图偏好已保存');
                      },
                      child: const Text('保存地图偏好'),
                    ),
                    TextButton(
                      onPressed: () => launch(),
                      child: Text(
                        p == null || placeStale(d, target)
                            ? '搜索目的地'
                            : '从当前位置导航',
                      ),
                    ),
                    if (isTransport(d['type']) &&
                        placeText(d, 'origin').isNotEmpty)
                      TextButton(
                        onPressed: () => launch(route: true),
                        child: const Text('查看起终点路线'),
                      ),
                    TextButton(
                      onPressed: () => launch(web: true),
                      child: const Text('网页搜索 / 打开'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text:
                                '${p?['name'] ?? ''} ${p?['address'] ?? ''} ${placeText(d, target)}${p == null ? '' : '\n${coordinates(p)} (WGS84)'}'
                                    .trim(),
                          ),
                        );
                        if (c.mounted) set(() => message = '地址已复制');
                      },
                      child: const Text('复制地址'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}

class NavigationActions extends StatelessWidget {
  final Store store;
  final Map<String, dynamic> data;
  final PlanNode? node;
  final String? slot;
  const NavigationActions({
    super.key,
    required this.store,
    required this.data,
    this.node,
    this.slot,
  });
  @override
  Widget build(BuildContext context) {
    final target =
        slot ??
        (node == null
            ? (isTransport(data['type']) ? 'destination' : 'place')
            : navigationSlot(node!));
    final valid =
        linkedPlace(data, target) != null && !placeStale(data, target);
    final label = !valid
        ? (target == 'origin'
              ? '搜索地点 · 出发地'
              : node?.end == true
              ? '搜索地点 · 到达地'
              : '搜索地点')
        : target == 'origin'
        ? '前往出发地'
        : node?.end == true
        ? '前往到达地'
        : '导航';
    final origin = isTransport(data['type']) && hasPlace(data, 'origin');
    if (!hasPlace(data, target) && !origin) return const SizedBox.shrink();
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasPlace(data, target))
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            icon: Icon(valid ? Icons.navigation_outlined : Icons.search),
            label: Text(label),
            onPressed: () => navigatePlace(context, store, data, slot: target),
          ),
        PopupMenuButton<String>(
          tooltip: '导航选项',
          onSelected: (value) => navigatePlace(
            context,
            store,
            data,
            slot: value == 'origin'
                ? 'origin'
                : hasPlace(data, target)
                ? target
                : 'origin',
            options: value == 'preferences',
          ),
          itemBuilder: (_) => [
            if (origin && target != 'origin')
              const PopupMenuItem(value: 'origin', child: Text('前往起点')),
            const PopupMenuItem(value: 'preferences', child: Text('地图偏好与备用方式')),
          ],
        ),
      ],
    );
  }
}
