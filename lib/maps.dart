import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'model.dart';
import 'places.dart';
import 'planner.dart';
import 'store.dart';
import 'map_links.dart';

Future<bool> openMapUrl(Uri uri) async {
  if (Platform.isWindows && uri.scheme != 'https') return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> openBoundPlace(
  BuildContext context,
  Map<String, dynamic> binding, {
  bool fallback = false,
}) async {
  final url = binding['url'] as String;
  if (mapLinkProvider(url) == null) return;
  final ok = !fallback && await openMapUrl(Uri.parse(url));
  if (!context.mounted) return;
  if (ok) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已请求浏览器打开原地图链接')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(fallback ? '地点备用方式' : '无法打开地图网页'),
      content: SelectableText('$url\n绑定已保留。请检查默认浏览器与 HTTPS 关联；此状态不代表网页或地点无效。'),
      actions: [
        TextButton(
          onPressed: () async {
            final ok = await openMapUrl(Uri.parse(url));
            if (c.mounted) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(content: Text(ok ? '已请求浏览器打开' : '仍无法打开，请复制链接')),
              );
            }
          },
          child: const Text('重试'),
        ),
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
          child: const Text('复制链接'),
        ),
        TextButton(
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text: '${binding['name']}\n${binding['address']}\n$url',
            ),
          ),
          child: const Text('复制地点信息'),
        ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
}

Future<void> searchPreferences(BuildContext context, Store store) async {
  var region = store.setting('mapRegion') ?? 'domestic';
  var provider =
      store.setting('mapProvider:$region') ??
      (region == 'domestic' ? 'baidu' : 'google');
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('搜索地图偏好'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('仅影响今后的地点搜索，不改变已有地点链接。偏好只保存在本机。'),
            DropdownButtonFormField<String>(
              initialValue: region,
              items: const [
                DropdownMenuItem(value: 'domestic', child: Text('国内')),
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
                DropdownMenuItem(value: 'google', child: Text('Google Maps')),
                DropdownMenuItem(value: 'amap', child: Text('高德地图网页')),
              ],
              onChanged: (v) => set(() => provider = v!),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              store.setSetting('mapRegion', region);
              store.setSetting('mapProvider:$region', provider);
              Navigator.pop(c);
            },
            child: const Text('保存偏好'),
          ),
        ],
      ),
    ),
  );
}

Future<void> placeFallback(
  BuildContext context,
  Store store,
  Map<String, dynamic> d,
  String slot,
) async {
  final p = locationBinding(d, slot);
  if (p?['url'] is String) {
    await openBoundPlace(context, p!, fallback: true);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('地点备用方式'),
      content: SelectableText('${placeText(d, slot)}\n${p?['address'] ?? ''}'),
      actions: [
        TextButton(
          onPressed: () => navigatePlace(c, store, d, slot: slot),
          child: const Text('重试'),
        ),
        TextButton(
          onPressed: () async {
            if (store.setting('mapRegion') == null) {
              await searchPreferences(c, store);
            }
            if (!c.mounted || store.setting('mapRegion') == null) return;
            final provider =
                store.setting('mapProvider:${store.setting('mapRegion')}') ??
                'google';
            final ok = await openMapUrl(
              mapSearchUri(provider, placeText(d, slot), ''),
            );
            if (c.mounted) {
              ScaffoldMessenger.of(c).showSnackBar(
                SnackBar(
                  content: Text(ok ? '已请求打开网页搜索，请核对地点' : '未能打开，地点信息仍保留'),
                ),
              );
            }
          },
          child: const Text('网页打开'),
        ),
        TextButton(
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text: '${placeText(d, slot)}\n${p?['address'] ?? ''}',
            ),
          ),
          child: const Text('复制地点信息'),
        ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
}

class PlaceLinks extends StatelessWidget {
  final Store store;
  final PlanNode node;
  final VoidCallback onEdit;
  const PlaceLinks({
    super.key,
    required this.store,
    required this.node,
    required this.onEdit,
  });
  @override
  Widget build(BuildContext context) {
    final d = node.item.data;
    final visits = mapVisits([
      node,
    ], daily: true).where((v) => hasPlace(d, v.slot)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in visits)
          Builder(
            builder: (c) {
              final binding = locationBinding(d, v.slot),
                  text = placeText(d, v.slot);
              final label = text.isNotEmpty ? text : binding?['name'] ?? '地点';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () =>
                              navigatePlace(c, store, d, slot: v.slot),
                          child: Text(
                            binding?['url'] != null
                                ? label
                                : '${binding == null || v.stale ? '搜索地点' : '导航'} · $label',
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '地点操作',
                        onSelected: (a) {
                          if (a == 'edit') {
                            onEdit();
                          } else if (a == 'preferences') {
                            searchPreferences(c, store);
                          } else if (binding?['url'] is String) {
                            openBoundPlace(c, binding!, fallback: true);
                          } else {
                            placeFallback(c, store, d, v.slot);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(binding == null ? '绑定地点' : '管理绑定'),
                          ),
                          const PopupMenuItem(
                            value: 'preferences',
                            child: Text('搜索地图偏好'),
                          ),
                          const PopupMenuItem(
                            value: 'fallback',
                            child: Text('备用方式'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (v.stale)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text('⚠ 名称已修改，请核对绑定地点'),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class UnboundPlaces extends StatelessWidget {
  final List<PlanNode> nodes;
  final ValueChanged<Record> onItem;
  const UnboundPlaces({super.key, required this.nodes, required this.onItem});
  @override
  Widget build(BuildContext context) {
    final missing = mapVisits(nodes, daily: true)
        .where(
          (v) =>
              placeText(v.node.item.data, v.slot).isNotEmpty &&
              locationBinding(v.node.item.data, v.slot) == null,
        )
        .toList();
    if (missing.isEmpty) return const SizedBox.shrink();
    return TextButton(
      onPressed: () async {
        if (missing.length == 1) {
          onItem(missing.single.node.item);
          return;
        }
        final r = await showDialog<Record>(
          context: context,
          builder: (c) => SimpleDialog(
            title: const Text('选择未绑定地点'),
            children: [
              for (final v in missing)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, v.node.item),
                  child: Text(
                    '${placeText(v.node.item.data, v.slot)} · ${itemTitle(v.node.item.data)}',
                  ),
                ),
            ],
          ),
        );
        if (r != null && context.mounted) onItem(r);
      },
      child: Text('有 ${missing.length} 个地点未绑定'),
    );
  }
}

Future<void> navigatePlace(
  BuildContext context,
  Store store,
  Map<String, dynamic> d, {
  String? slot,
  bool options = false,
}) async {
  final target =
      slot ??
      (isTransport(d['type'])
          ? 'destination'
          : placeSlots(d).firstOrNull ?? 'place');
  final binding = locationBinding(d, target);
  if (options) {
    await searchPreferences(context, store);
    return;
  }
  if (binding?['url'] is String) {
    if (placeStale(d, target)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名称已修改，请核对绑定地点')));
    }
    await openBoundPlace(context, binding!);
    return;
  }
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
    final ok = await openMapUrl(
      Theme.of(context).platform == TargetPlatform.windows
          ? mapSearchUri(provider, placeText(d, target), '')
          : navigationUri(provider, d, target),
    );
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
            Theme.of(context).platform == TargetPlatform.windows
                ? mapSearchUri(provider, placeText(d, target), '')
                : navigationUri(provider, d, target, route: route, web: web),
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
                if (Theme.of(context).platform != TargetPlatform.windows)
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
                    DropdownMenuItem(value: 'amap', child: Text('高德地图网页')),
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
                        Theme.of(context).platform == TargetPlatform.windows ||
                                provider == 'amap' ||
                                p == null ||
                                placeStale(d, target)
                            ? '搜索目的地'
                            : '从当前位置导航',
                      ),
                    ),
                    if (Theme.of(context).platform != TargetPlatform.windows &&
                        provider != 'amap' &&
                        isTransport(d['type']) &&
                        placeText(d, 'origin').isNotEmpty)
                      TextButton(
                        onPressed: () {
                          if (linkedPlace(d, 'origin') == null ||
                              linkedPlace(d, 'destination') == null) {
                            ScaffoldMessenger.of(c).showSnackBar(
                              const SnackBar(
                                content: Text('将按文字请求路线，请核对起终点；分享链接不会拼接为路线。'),
                              ),
                            );
                          }
                          launch(route: true);
                        },
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
    final hasLink = locationBinding(data, target)?['url'] is String;
    final label = Theme.of(context).platform == TargetPlatform.windows
        ? (locationBinding(data, target)?['url'] is String
              ? '打开地图网页'
              : '搜索地图网页')
        : hasLink
        ? (target == 'origin'
              ? '打开地图地点 · 出发地'
              : node?.end == true
              ? '打开地图地点 · 到达地'
              : '打开地图地点')
        : !valid
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
            const PopupMenuItem(value: 'preferences', child: Text('搜索地图偏好')),
          ],
        ),
      ],
    );
  }
}
