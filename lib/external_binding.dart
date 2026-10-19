import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'map_links.dart';
import 'maps.dart';
import 'places.dart';
import 'share_inbox.dart';
import 'store.dart';

String placeSlotLabel(String slot) => slot == 'origin'
    ? '起点'
    : slot == 'destination'
    ? '终点'
    : '地点';

class ExternalBindingPage extends StatefulWidget {
  final Store store;
  final String tripId, target, slot, sourceText;
  final String? itemId;
  final Map<String, dynamic>? original;
  const ExternalBindingPage({
    super.key,
    required this.store,
    required this.tripId,
    required this.target,
    required this.slot,
    required this.sourceText,
    this.itemId,
    this.original,
  });
  @override
  State<ExternalBindingPage> createState() => _ExternalBindingPageState();
}

class _ExternalBindingPageState extends State<ExternalBindingPage> {
  late final name = TextEditingController(
    text: widget.original?['name'] ?? widget.sourceText,
  );
  late final address = TextEditingController(
    text: widget.original?['address'] ?? '',
  );
  late final query = TextEditingController(text: widget.sourceText);
  final area = TextEditingController(), shared = TextEditingController();
  String? selected, shareId, error, region;
  List<String> links = [];
  bool launching = false;
  bool get windows => Theme.of(context).platform == TargetPlatform.windows;
  @override
  void initState() {
    super.initState();
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
      error = links.isEmpty
          ? '未识别到受支持的百度、Google 或高德 地图 HTTPS 链接。请复制地点分享链接，不会自动绑定。'
          : null;
    });
  }

  @override
  void dispose() {
    MapShareInbox.instance.removeListener(receive);
    for (final c in [name, address, query, area, shared]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> search({bool web = false}) async {
    if (region == null || query.text.trim().isEmpty) {
      setState(() => error = '请填写地点名称，并选择地点所在地区。');
      return;
    }
    final provider =
        widget.store.setting('mapProvider:$region') ??
        (region == 'domestic' ? 'baidu' : 'google');
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('绑定${placeSlotLabel(widget.slot)}')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('确认目标：${widget.target} · ${placeSlotLabel(widget.slot)}'),
                const Text('确认绑定只写入草稿；返回行程后仍需点击“保存行程”。'),
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
                    decoration: const InputDecoration(labelText: '搜索地图（记住偏好）'),
                    items: const [
                      DropdownMenuItem(value: 'baidu', child: Text('百度地图')),
                      DropdownMenuItem(value: 'amap', child: Text('高德地图网页')),
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
                    if (!windows)
                      TextButton(
                        onPressed: launching ? null : () => search(web: true),
                        child: const Text('网页搜索'),
                      ),
                  ],
                ),
                TextField(
                  controller: shared,
                  maxLines: 3,
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
                if (error != null) Text(error!),
                if (links.length > 1) const Text('收到多个链接，请明确选择本次绑定的地点：'),
                for (final link in links)
                  ListTile(
                    title: Text(mapProviderName(mapLinkProvider(link))),
                    subtitle: Text(link),
                    leading: Icon(
                      selected == link
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    onTap: () => setState(() => selected = link),
                  ),
                TextField(
                  controller: name,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '地点名称（请核对）'),
                ),
                TextField(
                  controller: address,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: '地址或说明（可选，请核对）'),
                ),
                const Text(
                  '未解析地点详情。仅绑定原链接，不代表地点已准确验证；请核对名称、地址及分享对象，不要把地图视角或路线当作地点。',
                ),
                if (widget.original != null)
                  const Text('更换后旧坐标保留为历史信息，不再用于新地点导航。取消不改变原关联。'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
              onPressed:
                  selected == null ||
                      name.text.length > 2000 ||
                      address.text.length > 2000
                  ? null
                  : () async {
                      final old = widget.original;
                      final result = <String, dynamic>{
                        'url': selected,
                        'provider': mapLinkProvider(selected!),
                        'name': name.text.trim(),
                        'address': address.text.trim(),
                        'sourceText': widget.sourceText,
                        if (old != null &&
                            (old['lat'] != null ||
                                old['previousPosition'] != null))
                          'previousPosition': old['lat'] != null
                              ? old
                              : old['previousPosition'],
                      };
                      await MapShareInbox.instance.acknowledge(shareId);
                      widget.store.setSetting('pendingMapBinding', '');
                      if (context.mounted) Navigator.pop(context, result);
                    },
              child: const Text('确认绑定到当前草稿'),
            ),
          ),
        ],
      ),
    ),
  );
}
