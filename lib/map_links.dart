String? mapLinkProvider(String value) {
  if (value.length > 4096 || RegExp(r'\s').hasMatch(value)) return null;
  final u = Uri.tryParse(value);
  if (u == null || u.scheme != 'https' || u.userInfo.isNotEmpty || u.hasPort) {
    return null;
  }
  if ((u.host == 'maps.app.goo.gl' && u.path.length > 1) ||
      (u.host == 'goo.gl' && u.path.startsWith('/maps/')) ||
      (['www.google.com', 'google.com'].contains(u.host) &&
          u.path.startsWith('/maps/')) ||
      (u.host == 'maps.google.com' &&
          (u.path == '/' || u.path.startsWith('/maps')))) {
    return 'google';
  }
  if ((u.host == 'j.map.baidu.com' && u.path.length > 1) ||
      (u.host == 'map.baidu.com' && u.path.startsWith('/'))) {
    return 'baidu';
  }
  if ((u.host == 'surl.amap.com' && u.path.length > 1) ||
      (['uri.amap.com', 'www.amap.com', 'amap.com'].contains(u.host) &&
          u.path.startsWith('/'))) {
    return 'amap';
  }
  return null;
}

List<String> sharedMapLinks(String text) {
  if (text.length > 20000) return [];
  return RegExp(r'''https://[^\s<>"“”]+''')
      .allMatches(text)
      .map((m) => m[0]!.replaceFirst(RegExp(r'[。，；！、）)\]]+$'), ''))
      .where((s) => mapLinkProvider(s) != null)
      .toSet()
      .toList();
}

String mapProviderName(dynamic provider) => switch (provider) {
  'baidu' => '百度地图',
  'google' => 'Google Maps',
  'amap' => '高德地图',
  'osm' => 'OpenStreetMap',
  'manual' => '历史手动选点',
  _ => '历史地点',
};

Uri mapSearchUri(String provider, String name, String city) {
  if (provider == 'google') {
    return Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': [name, city].where((s) => s.isNotEmpty).join(' '),
    });
  }
  if (provider == 'amap') {
    return Uri.https('uri.amap.com', '/search', {
      'keyword': name,
      if (city.isNotEmpty) 'city': city,
      'view': 'list',
      'src': 'HowDoI',
      'callnative': '0',
    });
  }
  return Uri.https('api.map.baidu.com', '/place/search', {
    'query': name,
    'region': city.isEmpty ? '全国' : city,
    'output': 'html',
    'src': 'webapp.k1taproject.howdoi',
  });
}
