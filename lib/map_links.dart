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
