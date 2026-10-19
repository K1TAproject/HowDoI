import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'map_links.dart';
import 'maps.dart';
import 'places.dart';
import 'share_inbox.dart';
import 'store.dart';

String placeSlotLabel(String slot) => slot.startsWith('activity:')
    ? '活动地点'
    : slot == 'origin'
    ? '起点'
    : slot == 'destination'
    ? '终点'
    : '地点';

class ExternalBindingPage extends StatefulWidget {
  final Store store;
  final String tripId, target, slot, sourceText;
  final String? itemId;
  final Map<String, dynamic>? original;
  final ValueChanged<Map<String, dynamic>?>? onFinished;
  const ExternalBindingPage({
    super.key,
    required this.store,
    required this.tripId,
    required this.target,
    required this.slot,
    required this.sourceText,
    this.itemId,
    this.original,
    this.onFinished,
  });
  @override
  State<ExternalBindingPage> createState() => _ExternalBindingPageState();
}

class _ExternalBindingPageState extends State<ExternalBindingPage> {
  late final name = TextEditingController(
    text: widget.sourceText.isNotEmpty
        ? widget.sourceText
        : widget.original?['name'] ?? '',
  );
  late final address = TextEditingController(
    text: widget.original?['address'] ?? '',
  );
  late final query = TextEditingController(text: widget.sourceText);
  final area = TextEditingController(), shared = TextEditingController();
  String? selected, shareId, error, region;
  List<String> links = [];
  bool launching = false, searchExpanded = false, metadataExpanded = false;
  bool? keepPosition;
  late final originalPosition = currentPosition(widget.original);
  late final initialCoordinates = originalPosition == null
      ? ''
      : '${originalPosition!['lat']}, ${originalPosition!['lon']}';
  late final coordinateInput = TextEditingController(text: initialCoordinates);
  bool get windows => Theme.of(context).platform == TargetPlatform.windows;
  @override
  void initState() {
    super.initState();
    shared.text = widget.original?['url'] ?? '';
    links = sharedMapLinks(shared.text);
    selected = links.length == 1 ? links.single : null;
    final country = widget.original?['country'];
    region = country == 'cn'
        ? 'domestic'
        : country is String && country.isNotEmpty
        ? 'overseas'
        : widget.store.setting('mapRegion');
    MapShareInbox.instance.addListener(receive);
    receive();
  }

  void receive() {
    final incoming = MapShareInbox.instance.value;
    if (incoming == null || incoming['id'] == shareId) return;
    shareId = incoming['id'];
    shared.text = incoming['text']!;
    parse();
  }

  void parse() {
    setState(() {
      links = sharedMapLinks(shared.text);
      selected = links.length == 1 ? links.single : null;
      keepPosition = null;
      error = links.isEmpty && shared.text.trim().isNotEmpty
          ? '未识别到受支持的百度、Google 或高德 地图 HTTPS 链接。请复制地点分享链接，不会自动绑定。'
          : null;
    });
  }

  @override
  void dispose() {
    MapShareInbox.instance.removeListener(receive);
    for (final c in [name, address, query, area, shared, coordinateInput]) {
      c.dispose();
    }
    super.dispose();
  }

  void finish(Map<String, dynamic>? result) {
    if (widget.onFinished != null) {
      widget.onFinished!(result);
    } else {
      Navigator.pop(context, result);
    }
  }

  Future<void> search({bool web = false, bool copy = false}) async {
    if (region == null || query.text.trim().isEmpty) {
      setState(() => error = '请填写地点名称，并选择地点所在地区。');
      return;
    }
    final provider =
        widget.store.setting('mapProvider:$region') ??
        (region == 'domestic' ? 'baidu' : 'google');
    if (copy) {
      await Clipboard.setData(
        ClipboardData(
          text: mapSearchUri(
            provider,
            query.text.trim(),
            area.text.trim(),
          ).toString(),
        ),
      );
      if (mounted) setState(() => error = '已复制搜索网址。可在已有标签页地址栏粘贴后搜索；未打开或控制浏览器。');
      return;
    }
    widget.store.setSetting('mapRegion', region!);
    widget.store.setSetting(
      'pendingMapBinding',
      jsonEncode({
        'trip': widget.tripId,
        'item': widget.itemId,
        'slot': widget.slot,
      }),
    );
    setState(() {
      launching = true;
      error = null;
    });
    final d = <String, dynamic>{
      'type': '游览',
      'name': '${query.text.trim()} ${area.text.trim()}',
      'fields': <String, dynamic>{},
    };
    final ok = await openMapUrl(
      windows || provider == 'amap'
          ? mapSearchUri(provider, query.text.trim(), area.text.trim())
          : navigationUri(provider, d, 'place', web: web),
    );
    if (mounted) {
      setState(() {
        launching = false;
        error = ok
            ? (windows
                  ? '已请求浏览器打开。选定地点后复制分享内容，返回此处粘贴；尚未验证网页加载或地点。'
                  : '已请求打开搜索。请在地图中选定地点，分享至 HowDoI；也可复制链接后返回粘贴。')
            : '无法唤起地图，请尝试网页搜索或粘贴地图链接。';
      });
    }
  }

  Future<void> confirmBinding() async {
    try {
      if (shared.text.trim().isNotEmpty && selected == null) {
        throw const FormatException('请提供支持的地图链接；多个链接需选择一个');
      }
      var position = parsePosition(coordinateInput.text);
      if (originalPosition != null &&
          selected != widget.original?['url'] &&
          position != null &&
          keepPosition == null) {
        throw const FormatException('链接已更换，请明确选择保留或清除坐标，并核对是否同一地点');
      }
      if (position != null && coordinateInput.text == initialCoordinates) {
        position = {
          'lat': originalPosition!['lat'],
          'lon': originalPosition!['lon'],
          'crs': 'WGS84',
          'source': originalPosition!['source'] ?? widget.original!['provider'],
          'confirmed': true,
        };
      }
      if (selected == null && position == null) {
        throw const FormatException('请填写地图链接或经纬度');
      }
      if (name.text.length > 2000 || address.text.length > 2000) {
        throw const FormatException('名称或地址过长');
      }
      final old = widget.original;
      final result = <String, dynamic>{
        ...?old,
        'provider': selected == null ? 'manual' : mapLinkProvider(selected!),
        'name': name.text.trim(),
        'address': address.text.trim(),
        'sourceText': widget.sourceText,
        if (old?['lat'] != null) 'previousPosition': old,
      };
      for (final key in ['lat', 'lon', 'crs', 'url', 'position']) {
        result.remove(key);
      }
      if (selected != null) result['url'] = selected;
      if (position != null) result['position'] = position;
      await MapShareInbox.instance.acknowledge(shareId);
      widget.store.setSetting('pendingMapBinding', '');
      if (mounted) finish(result);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(onPressed: () => finish(null)),
      title: Text('绑定${placeSlotLabel(widget.slot)}'),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('确认目标：${widget.target} · ${placeSlotLabel(widget.slot)}'),
                const Text('确认只写入草稿，返回后仍需保存行程。'),
                TextField(
                  controller: name,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '地点名称（请核对）'),
                ),
                TextField(
                  controller: shared,
                  maxLines: 2,
                  maxLength: 20000,
                  decoration: const InputDecoration(labelText: '地图分享文字或链接'),
                  onChanged: (_) => parse(),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.paste),
                  label: const Text('粘贴地图分享内容'),
                  onPressed: () async {
                    final v = await Clipboard.getData(Clipboard.kTextPlain);
                    if (!mounted) return;
                    shared.text = v?.text ?? '';
                    shareId = null;
                    parse();
                  },
                ),
                if (links.length > 1) ...[
                  const Text('收到多个链接，请选择本次地点：'),
                  for (final link in links)
                    ListTile(
                      leading: Icon(
                        selected == link
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(mapProviderName(mapLinkProvider(link))),
                      subtitle: Text(link),
                      onTap: () => setState(() {
                        selected = link;
                        keepPosition = null;
                      }),
                    ),
                ],
                TextField(
                  controller: coordinateInput,
                  decoration: const InputDecoration(
                    labelText: '经纬度（可选，纬度，经度）',
                    hintText: '40.828178925867995, 140.6934585811546',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const Text(
                  '仅支持 Google 地图复制的 WGS84，顺序为纬度、经度。请填写具体地点，不用地图视角中心；百度/高德原生坐标不能直接填写。格式有效不代表地点准确。',
                ),
                if (originalPosition != null &&
                    selected != widget.original?['url'] &&
                    coordinateInput.text.trim().isNotEmpty)
                  DropdownButtonFormField<bool>(
                    initialValue: keepPosition,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '链接已更换：处理已有坐标',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: true,
                        child: Text('保留坐标，已核对仍为同一地点'),
                      ),
                      DropdownMenuItem(value: false, child: Text('清除坐标')),
                    ],
                    onChanged: (v) => setState(() {
                      keepPosition = v;
                      if (v == false) coordinateInput.clear();
                    }),
                  ),
                if (coordinateInput.text.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() {
                      coordinateInput.clear();
                      keepPosition = false;
                    }),
                    child: const Text('清除坐标'),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ExpansionTile(
                  key: const ValueKey('binding-search-tools'),
                  initiallyExpanded: searchExpanded,
                  onExpansionChanged: (v) => searchExpanded = v,
                  title: const Text('去地图搜索'),
                  children: [
                    TextField(
                      controller: query,
                      maxLength: 300,
                      decoration: const InputDecoration(labelText: '搜索地点名称'),
                    ),
                    TextField(
                      controller: area,
                      maxLength: 300,
                      decoration: const InputDecoration(labelText: '城市或地区（可选）'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: region,
                      decoration: const InputDecoration(labelText: '地点所在地区'),
                      items: const [
                        DropdownMenuItem(value: 'domestic', child: Text('国内')),
                        DropdownMenuItem(value: 'overseas', child: Text('海外')),
                      ],
                      onChanged: (v) => setState(() => region = v),
                    ),
                    if (region != null)
                      DropdownButtonFormField<String>(
                        key: ValueKey(region),
                        initialValue:
                            widget.store.setting('mapProvider:$region') ??
                            (region == 'domestic' ? 'baidu' : 'google'),
                        decoration: const InputDecoration(
                          labelText: '搜索地图（记住偏好）',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'baidu', child: Text('百度地图')),
                          DropdownMenuItem(
                            value: 'amap',
                            child: Text('高德地图网页'),
                          ),
                          DropdownMenuItem(
                            value: 'google',
                            child: Text('Google Maps'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            widget.store.setSetting('mapProvider:$region', v);
                          }
                        },
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: launching ? null : () => search(),
                          child: Text(windows ? '打开地图网页搜索' : '打开地图搜索'),
                        ),
                        if (windows)
                          TextButton.icon(
                            onPressed: launching
                                ? null
                                : () => search(copy: true),
                            icon: const Icon(Icons.copy),
                            label: const Text('复制搜索网址'),
                          ),
                        if (!windows)
                          TextButton(
                            onPressed: launching
                                ? null
                                : () => search(web: true),
                            child: const Text('网页搜索'),
                          ),
                      ],
                    ),
                    if (windows)
                      const Text(
                        '默认浏览器接口不支持指定或跟踪标签页，打开搜索可能新增标签页。可复制搜索网址，在已有标签页手动搜索。',
                      ),
                  ],
                ),
                ExpansionTile(
                  key: const ValueKey('binding-metadata'),
                  initiallyExpanded: metadataExpanded,
                  onExpansionChanged: (v) => metadataExpanded = v,
                  title: const Text('地址与来源（可选）'),
                  children: [
                    if (selected != null)
                      Text(
                        '链接来源：${mapProviderName(mapLinkProvider(selected!))}',
                      ),
                    const Text('手工坐标来源：Google / WGS84。链接来源与坐标来源独立；不解析链接坐标。'),
                    TextField(
                      controller: address,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        labelText: '地址或说明（可选，请核对）',
                      ),
                    ),
                    if (widget.original?['previousPosition'] != null ||
                        widget.original?['lat'] != null)
                      const Text('历史坐标信息保留，不自动作为新地点位置。'),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
              onPressed: shared.text.trim().isNotEmpty && selected == null
                  ? null
                  : confirmBinding,
              child: const Text('确认绑定到当前草稿'),
            ),
          ),
        ],
      ),
    ),
  );
}
