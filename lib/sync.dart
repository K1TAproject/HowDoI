import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'model.dart';
import 'store.dart';
import 'editors.dart';

Map<String, String> makeIdentity(Object? _) {
  final pair = CryptoUtils.generateRSAKeyPair();
  final private = pair.privateKey as RSAPrivateKey,
      public = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'HowDoI local sync'},
    private,
    public,
  );
  final cert = X509Utils.generateSelfSignedCertificate(private, csr, 3650);
  final der = base64Decode(
    cert
        .split('\n')
        .map((l) => l.trim())
        .where((l) => !l.startsWith('---'))
        .join(),
  );
  return {
    'cert': cert,
    'key': CryptoUtils.encodeRSAPrivateKeyToPem(private),
    'fingerprint': sha256.convert(der).toString(),
    'token': base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ),
  };
}

Future<String> limitedBody(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(const Duration(seconds: 20))) {
    bytes.addAll(chunk);
    if (bytes.length > 20 * 1024 * 1024) {
      throw const FormatException('同步数据超过 20 MB');
    }
  }
  return utf8.decode(bytes);
}

class SyncService extends ChangeNotifier {
  final Store store;
  final bool host;
  final int port;
  bool enabled = false, active = true, busy = false, _disposed = false;
  String status = '离线使用 · 尚未配对';
  HttpServer? _server;
  RawDatagramSocket? _discovery;
  Timer? _timer;
  DateTime? _last;
  int _syncedGeneration = -1;
  Map<String, dynamic>? identity, peer;
  SyncService(this.store, {required this.host, this.port = 47821}) {
    store.addListener(_changed);
  }
  void _status(String text) {
    status = text;
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    if (enabled && store.generation != _syncedGeneration) _status('有修改待同步');
  }

  Future<void> restore() async {
    try {
      final savedIdentity = store.setting('sync.identity');
      if (savedIdentity != null && savedIdentity.isNotEmpty) {
        identity = Map<String, dynamic>.from(jsonDecode(savedIdentity));
      }
      final savedPeer = store.setting('sync.peer');
      if (savedPeer != null && savedPeer.isNotEmpty) {
        peer = Map<String, dynamic>.from(jsonDecode(savedPeer));
      }
      if (store.setting('sync.enabled') == 'true') await start();
    } catch (e) {
      _status('同步未启动：$e');
    }
  }

  Future<void> start() async {
    if (enabled) return;
    if (host) {
      if (identity == null) {
        _status('正在生成本机配对凭据…');
        identity = await compute(makeIdentity, null);
        store.setSetting('sync.identity', jsonEncode(identity));
      }
      final context = SecurityContext();
      context.useCertificateChainBytes(utf8.encode(identity!['cert']));
      context.usePrivateKeyBytes(utf8.encode(identity!['key']));
      _server = await HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        port,
        context,
      );
      _server!.listen(_serve, onError: (Object e) => _status('同步连接失败：$e'));
      try {
        _discovery = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          47822,
        );
        _discovery!.listen((event) {
          if (event == RawSocketEvent.read) {
            final d = _discovery!.receive();
            if (d != null &&
                utf8.decode(d.data, allowMalformed: true) ==
                    'howdoi-discover-v1') {
              _discovery!.send(
                utf8.encode(
                  jsonEncode({
                    'app': 'howdoi',
                    'fingerprint': identity!['fingerprint'],
                    'port': _server!.port,
                  }),
                ),
                d.address,
                d.port,
              );
            }
          }
        });
      } catch (_) {
        /* Manual address remains available if UDP discovery is blocked. */
      }
    } else if (peer == null) {
      throw const FormatException('请先填写电脑的配对文本');
    }
    enabled = true;
    store.setSetting('sync.enabled', 'true');
    _status(host ? '等待手机连接' : '设备未连接');
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => tick());
    await tick();
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (!active) {
        request.response.statusCode = 503;
        return;
      }
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer ${identity!['token']}') {
        request.response.statusCode = 401;
        return;
      }
      if (request.method != 'POST' ||
          !['/sync', '/ack'].contains(request.uri.path)) {
        request.response.statusCode = 404;
        return;
      }
      final text = await limitedBody(request);
      if (request.uri.path == '/ack') {
        final ack = jsonDecode(text);
        final digest = sha256
            .convert(utf8.encode(store.export(sync: true)))
            .toString();
        if (ack is Map && ack['digest'] == digest) {
          _syncedGeneration = store.generation;
          _last = DateTime.now();
          _status(
            '已同步 · ${_last!.hour.toString().padLeft(2, '0')}:${_last!.minute.toString().padLeft(2, '0')}',
          );
        }
        request.response.write(
          jsonEncode({'synced': ack is Map && ack['digest'] == digest}),
        );
        return;
      }
      final envelope = jsonDecode(text);
      if (envelope is Map && envelope['version'] != 2) {
        request.response.statusCode = 409;
        request.response.write('数据版本不兼容，请使用支持 0.1.1 数据的客户端；未合并任何记录');
        _status('旧版客户端不兼容 · 请勿与 0.1.0 同步');
        return;
      }
      final clock = envelope is Map ? envelope['sentAt'] : null;
      if (clock is! int ||
          (DateTime.now().millisecondsSinceEpoch - clock).abs() > 300000) {
        request.response.statusCode = 409;
        request.response.write('设备时间相差超过五分钟，请校准');
        return;
      }
      final rows = decodeRecords(text, format: 'howdoi-sync');
      if (rows.any(
        (r) => r.modified > DateTime.now().microsecondsSinceEpoch + 300000000,
      )) {
        throw const FormatException('记录时间超前，请校准设备时间');
      }
      store.merge(rows);
      request.response.headers.contentType = ContentType.json;
      request.response.write(store.export(sync: true));
      _status('已接收 · 等待手机确认');
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write('数据未合并：${e.runtimeType}');
      _status('同步数据校验失败');
    } finally {
      await request.response.close();
    }
  }

  Future<String?> discover() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final found = Completer<String?>();
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final packet = socket!.receive();
          if (packet != null) {
            try {
              final m = jsonDecode(utf8.decode(packet.data));
              if (m['app'] == 'howdoi' &&
                  m['fingerprint'] == peer!['fingerprint'] &&
                  !found.isCompleted) {
                found.complete(packet.address.address);
              }
            } catch (_) {}
          }
        }
      });
      socket.send(
        utf8.encode('howdoi-discover-v1'),
        InternetAddress('255.255.255.255'),
        47822,
      );
      return await found.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  Future<String> _post(String path, String body) async {
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == peer!['fingerprint'];
    try {
      final req = await client.postUrl(
        Uri(
          scheme: 'https',
          host: peer!['host'],
          port: peer!['port'],
          path: path,
        ),
      );
      // No trusted roots: TLS proceeds only if the callback matches the paired
      // certificate fingerprint before any credentials are transmitted.
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${peer!['token']}',
      );
      req.headers.contentType = ContentType.json;
      req.write(body);
      final response = await req.close().timeout(const Duration(seconds: 20));
      final text = await limitedBody(response);
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 409
              ? text
              : '连接被拒绝（${response.statusCode}），请核对配对信息',
        );
      }
      return text;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> tick() async {
    if (!enabled || !active || busy || _disposed) return;
    if (host) {
      if (_last != null &&
          DateTime.now().difference(_last!) > const Duration(seconds: 35)) {
        _status(
          '设备未连接${store.generation != _syncedGeneration ? ' · 有修改待同步' : ''}',
        );
      }
      return;
    }
    busy = true;
    try {
      final snapshot =
          jsonDecode(store.export(sync: true)) as Map<String, dynamic>;
      snapshot['sentAt'] = DateTime.now().millisecondsSinceEpoch;
      String response;
      try {
        response = await _post('/sync', jsonEncode(snapshot));
      } on SocketException {
        final address = await discover();
        if (address == null) rethrow;
        peer!['host'] = address;
        store.setSetting('sync.peer', jsonEncode(peer));
        response = await _post('/sync', jsonEncode(snapshot));
      }
      final rows = decodeRecords(response, format: 'howdoi-sync');
      if (rows.any(
        (r) => r.modified > DateTime.now().microsecondsSinceEpoch + 300000000,
      )) {
        throw const FormatException('电脑记录时间超前，请校准');
      }
      store.merge(rows);
      final ours = jsonDecode(store.export(sync: true))['records'] as List,
          theirs = jsonDecode(response)['records'] as List;
      String canonical(List list) => jsonEncode(
        [...list]
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
      );
      if (canonical(ours) == canonical(theirs)) {
        final generation = store.generation;
        final acknowledged = jsonDecode(
          await _post(
            '/ack',
            jsonEncode({
              'digest': sha256.convert(utf8.encode(response)).toString(),
            }),
          ),
        );
        if (store.generation == generation && acknowledged['synced'] == true) {
          _syncedGeneration = generation;
          _last = DateTime.now();
          _status(
            '已同步 · ${_last!.hour.toString().padLeft(2, '0')}:${_last!.minute.toString().padLeft(2, '0')}',
          );
        }
      } else {
        _status('有修改待同步');
      }
    } catch (e) {
      _status('设备未连接 / 同步失败：$e');
    } finally {
      busy = false;
    }
  }

  Future<String> pairingText() async {
    if (!enabled) await start();
    final addresses = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final address =
        addresses
            .expand((i) => i.addresses)
            .where((a) => !a.isLoopback)
            .firstOrNull
            ?.address ??
        '127.0.0.1';
    return jsonEncode({
      'app': 'howdoi-pair',
      'version': 1,
      'host': address,
      'port': _server!.port,
      'fingerprint': identity!['fingerprint'],
      'token': identity!['token'],
    });
  }

  Future<void> pair(String text) async {
    final m = jsonDecode(text);
    if (m is! Map ||
        m['app'] != 'howdoi-pair' ||
        m['version'] != 1 ||
        m['host'] is! String ||
        m['port'] is! int ||
        m['port'] < 1 ||
        m['port'] > 65535 ||
        m['fingerprint'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(m['fingerprint']) ||
        m['token'] is! String ||
        m['token'].length < 40) {
      throw const FormatException('配对文本无效');
    }
    await stop();
    peer = Map<String, dynamic>.from(m);
    store.setSetting('sync.peer', jsonEncode(peer));
    await start();
  }

  Future<void> stop() async {
    enabled = false;
    store.setSetting('sync.enabled', 'false');
    _timer?.cancel();
    _timer = null;
    _discovery?.close();
    _discovery = null;
    await _server?.close(force: true);
    _server = null;
    _status('离线使用 · 同步已关闭');
  }

  Future<void> revoke() async {
    await stop();
    identity = null;
    peer = null;
    store.setSetting('sync.peer', '');
    store.setSetting('sync.identity', '');
    _status('配对已撤销');
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _discovery?.close();
    _server?.close(force: true);
    store.removeListener(_changed);
    super.dispose();
  }
}

Future<void> showSyncDialog(BuildContext context, SyncService sync) async {
  final text = TextEditingController();
  String? error;
  await formDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('设备同步'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sync.status),
                const SizedBox(height: 12),
                Text(
                  sync.host
                      ? '电脑和手机需处于同一 Wi-Fi 或热点。点击生成，将完整配对文本安全地传到自己的手机。文本含连接凭据，请勿公开。'
                      : '从电脑获取配对文本，粘贴到这里。之后双方打开应用时自动同步。',
                ),
                const SizedBox(height: 12),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(c).colorScheme.error),
                  ),
                Input('配对文本（可以修改 host 为电脑的局域网 IP）', text, lines: 6),
                if (sync.host)
                  OutlinedButton(
                    onPressed: () async {
                      try {
                        final value = await sync.pairingText();
                        if (c.mounted) set(() => text.text = value);
                      } catch (e) {
                        if (c.mounted) set(() => error = '$e');
                      }
                    },
                    child: const Text('生成 / 查看配对文本'),
                  ),
                if (sync.host)
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text.text));
                      if (c.mounted) notice(c, '已复制配对文本，请勿公开');
                    },
                    child: const Text('复制'),
                  ),
                if (!sync.host)
                  FilledButton(
                    onPressed: () async {
                      try {
                        await sync.pair(text.text.trim());
                        if (c.mounted) set(() => error = sync.status);
                      } catch (e) {
                        if (c.mounted) set(() => error = '$e');
                      }
                    },
                    child: const Text('配对并同步'),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '自动发现失败时可修改文本中的 host 地址。网络隔离或防火墙阻止时无法连接；无需关闭防火墙，仅允许本应用访问可信专用网络。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await sync.stop();
              if (c.mounted) set(() {});
            },
            child: const Text('关闭同步'),
          ),
          TextButton(
            onPressed: () async {
              await sync.revoke();
              if (c.mounted) set(() => text.clear());
            },
            child: const Text('撤销配对'),
          ),
          TextButton(
            onPressed: () async {
              try {
                await sync.start();
                await sync.tick();
                if (c.mounted) set(() => error = sync.status);
              } catch (e) {
                if (c.mounted) set(() => error = '$e');
              }
            },
            child: const Text('重新连接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('完成'),
          ),
        ],
      ),
    ),
  );
  text.dispose();
}
