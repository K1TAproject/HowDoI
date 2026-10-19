import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
  Timer? _saveTimer;
  Future<void>? _starting;
  int _epoch = 0;
  final _clients = <HttpClient>{};
  DateTime? _last;
  DateTime? get lastSuccess => _last;
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
    if (enabled && store.generation != _syncedGeneration) {
      _status('有修改待同步');
      if (!host) {
        _saveTimer?.cancel();
        _saveTimer = Timer(const Duration(milliseconds: 600), tick);
      }
    }
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
      _last = DateTime.tryParse(store.setting('sync.lastSuccess') ?? '');
      if (store.setting('sync.enabled') == 'true') await start();
    } catch (e) {
      _status('同步未启动：$e');
    }
  }

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (enabled) return;
    final epoch = _epoch;
    if (host) {
      if (identity == null) {
        _status('正在生成本机配对凭据…');
        final generated = await compute(makeIdentity, null);
        if (epoch != _epoch || _disposed) return;
        identity = generated;
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
      if (epoch != _epoch || _disposed) {
        await _server?.close(force: true);
        _server = null;
        return;
      }
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
          !['/hello', '/sync', '/ack'].contains(request.uri.path)) {
        request.response.statusCode = 404;
        return;
      }
      final text = await limitedBody(
        request,
      ).timeout(const Duration(seconds: 20));
      if (!active) {
        request.response.statusCode = 503;
        return;
      }
      request.response.headers.set(
        'x-howdoi-time',
        DateTime.now().millisecondsSinceEpoch,
      );
      if (request.uri.path == '/ack') {
        final ack = jsonDecode(text);
        final digest = sha256
            .convert(utf8.encode(store.export(sync: true)))
            .toString();
        if (ack is Map && ack['digest'] == digest) {
          _success();
        }
        request.response.write(
          jsonEncode({'synced': ack is Map && ack['digest'] == digest}),
        );
        return;
      }
      final envelope = jsonDecode(text);
      if (envelope is Map && envelope['version'] != 7) {
        request.response.statusCode = 409;
        request.response.write('数据协议不兼容，请更新两端应用；未合并任何记录');
        _status('旧版客户端不兼容 · 请更新两端版本');
        return;
      }
      final clock = envelope is Map ? envelope['sentAt'] : null;
      if (clock is! int ||
          (DateTime.now().millisecondsSinceEpoch - clock).abs() > 300000) {
        request.response.statusCode = 409;
        request.response.write('设备时间相差超过五分钟，请校准');
        _status('同步失败 · 设备时间相差超过五分钟，请校准');
        return;
      }
      if (request.uri.path == '/hello') {
        request.response.write(jsonEncode({'app': 'howdoi', 'version': 7}));
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
    } on FormatException catch (e) {
      request.response.statusCode = 400;
      request.response.write(
        e.message.contains('时间') ? '记录时间超前，请校准设备时间；未合并记录' : '数据未合并，请检查备份格式',
      );
      _status(e.message.contains('时间') ? '同步失败 · 记录时间超前，请校准设备时间' : '同步数据校验失败');
    } catch (_) {
      request.response.statusCode = 400;
      _status('同步数据校验失败');
    } finally {
      await request.response.close();
    }
  }

  Future<String?> discover([Map<String, dynamic>? target]) async {
    target ??= peer;
    final senders = <RawDatagramSocket>[];
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
                  m['fingerprint'] == target!['fingerprint'] &&
                  !found.isCompleted) {
                found.complete(packet.address.address);
              }
            } catch (_) {}
          }
        }
      });
      // Bind broadcasts to each interface so a VPN's default route does not
      // prevent discovery on the physical Wi-Fi interface.
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final address in interfaces.expand((i) => i.addresses)) {
        RawDatagramSocket? sender;
        try {
          sender = await RawDatagramSocket.bind(address, 0);
          sender.broadcastEnabled = true;
          sender.listen((event) {
            if (event != RawSocketEvent.read) return;
            final packet = sender?.receive();
            if (packet == null) return;
            try {
              final m = jsonDecode(utf8.decode(packet.data));
              if (m['app'] == 'howdoi' &&
                  m['fingerprint'] == target!['fingerprint'] &&
                  !found.isCompleted) {
                found.complete(packet.address.address);
              }
            } catch (_) {}
          });
          sender.send(
            utf8.encode('howdoi-discover-v1'),
            InternetAddress('255.255.255.255'),
            47822,
          );
          senders.add(sender);
        } catch (_) {
          sender?.close();
        }
      }
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
      for (final sender in senders) {
        sender.close();
      }
    }
  }

  Future<String> _post(
    String path,
    String body, [
    Map<String, dynamic>? target,
  ]) async {
    target ??= peer!;
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    _clients.add(client);
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == target!['fingerprint'];
    try {
      final req = await client
          .postUrl(
            Uri(
              scheme: 'https',
              host: target['host'],
              port: target['port'],
              path: path,
            ),
          )
          .timeout(const Duration(seconds: 5));
      req.followRedirects = false;
      // No trusted roots: TLS proceeds only if the callback matches the paired
      // certificate fingerprint before any credentials are transmitted.
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${target['token']}',
      );
      req.headers.contentType = ContentType.json;
      req.write(body);
      final response = await req.close().timeout(const Duration(seconds: 20));
      final text = await limitedBody(
        response,
      ).timeout(const Duration(seconds: 20));
      if (path == '/hello' && response.statusCode == 404) {
        throw const FormatException('电脑版本不支持安全配对，请先更新电脑应用');
      }
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 409 || response.statusCode == 400
              ? text
              : '连接被拒绝（${response.statusCode}），请核对配对信息',
        );
      }
      final clock = int.tryParse(response.headers.value('x-howdoi-time') ?? '');
      if (clock == null) throw const FormatException('电脑版本不支持安全配对，请先更新电脑应用');
      if ((DateTime.now().millisecondsSinceEpoch - clock).abs() > 300000) {
        throw const FormatException('设备时间相差超过五分钟，请校准');
      }
      return text;
    } finally {
      client.close(force: true);
      _clients.remove(client);
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
    final epoch = _epoch;
    _status('连接中${store.generation != _syncedGeneration ? ' · 有修改待同步' : ''}');
    try {
      final snapshot =
          jsonDecode(store.export(sync: true)) as Map<String, dynamic>;
      snapshot['sentAt'] = DateTime.now().millisecondsSinceEpoch;
      String response;
      try {
        response = await _post('/sync', jsonEncode(snapshot));
      } catch (e) {
        if (e is! SocketException &&
            e is! TimeoutException &&
            e is! HandshakeException) {
          rethrow;
        }
        final address = await discover();
        if (address == null || epoch != _epoch || !active) rethrow;
        final candidate = {...peer!, 'host': address};
        response = await _post('/sync', jsonEncode(snapshot), candidate);
        if (epoch != _epoch || !active) return;
        peer = candidate;
        store.setSetting('sync.peer', jsonEncode(candidate));
      }
      if (!active || epoch != _epoch || _disposed) return;
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
        if (!active || epoch != _epoch || _disposed) return;
        if (store.generation == generation && acknowledged['synced'] == true) {
          _success();
        } else {
          _status('有修改待同步');
        }
      } else {
        _status('有修改待同步');
      }
    } catch (e) {
      if (epoch == _epoch && !_disposed) {
        _status(
          '${syncError(e)}${store.generation != _syncedGeneration ? ' · 有修改待同步' : ''}',
        );
      }
    } finally {
      busy = false;
    }
  }

  void _success() {
    _syncedGeneration = store.generation;
    _last = DateTime.now();
    store.setSetting('sync.lastSuccess', _last!.toIso8601String());
    _status(
      '已同步 · ${_last!.hour.toString().padLeft(2, '0')}:${_last!.minute.toString().padLeft(2, '0')}',
    );
  }

  Future<String> pairingText() async {
    if (!enabled) await start();
    final addresses = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    addresses.sort(
      (a, b) => interfacePriority(a).compareTo(interfacePriority(b)),
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
      'addresses': addresses
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .take(8)
          .toList(),
    });
  }

  Future<void> pair(String text) async {
    if (busy) throw const FormatException('正在同步，请稍后再试');
    final m = parsePairing(text);
    final epoch = _epoch;
    busy = true;
    _status('连接中 · 正在验证电脑身份');
    var candidate = Map<String, dynamic>.from(m);
    try {
      final body = jsonEncode({
        'version': 7,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      });
      String response;
      try {
        response = await _post('/hello', body, candidate);
      } catch (e) {
        if (e is! SocketException &&
            e is! TimeoutException &&
            e is! HandshakeException) {
          rethrow;
        }
        final discovered = await discover(candidate);
        final addresses = <String>{
          ?discovered,
          ...((m['addresses'] as List?) ?? []).whereType<String>(),
        }.take(8);
        String? result;
        for (final address in addresses) {
          if (epoch != _epoch || _disposed) {
            throw const FormatException('配对已取消');
          }
          candidate = {...m, 'host': address};
          try {
            result = await _post('/hello', body, candidate);
            break;
          } on SocketException {
            continue;
          } on TimeoutException {
            continue;
          } on HandshakeException {
            continue;
          }
        }
        if (result == null) rethrow;
        response = result;
      }
      final hello = jsonDecode(response);
      if (hello is! Map || hello['app'] != 'howdoi' || hello['version'] != 7) {
        throw const FormatException('数据协议不兼容，请更新两端应用');
      }
      if (epoch != _epoch || _disposed) throw const FormatException('配对已取消');
      peer = candidate;
      store.setSetting('sync.peer', jsonEncode(peer));
    } catch (e) {
      if (epoch == _epoch && !_disposed) _status(syncError(e));
      rethrow;
    } finally {
      busy = false;
    }
    if (!enabled) {
      await start();
    } else {
      await tick();
    }
  }

  static Map<String, dynamic> parsePairing(String text) {
    dynamic m;
    try {
      m = jsonDecode(text);
    } catch (_) {
      throw const FormatException('不是有效的 HowDoI 配对二维码或文本');
    }
    if (m is! Map ||
        m['app'] != 'howdoi-pair' ||
        m['version'] != 1 ||
        m['host'] is! String ||
        InternetAddress.tryParse(m['host']) == null ||
        m['port'] is! int ||
        m['port'] < 1 ||
        m['port'] > 65535 ||
        m['fingerprint'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(m['fingerprint']) ||
        m['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_=-]{40,128}$').hasMatch(m['token']) ||
        (m['addresses'] != null &&
            (m['addresses'] is! List ||
                m['addresses'].length > 8 ||
                (m['addresses'] as List).any(
                  (a) => a is! String || InternetAddress.tryParse(a) == null,
                )))) {
      throw const FormatException('配对文本无效');
    }
    return Map<String, dynamic>.from(m);
  }

  Future<void> stop() async {
    _epoch++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _saveTimer?.cancel();
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
    _epoch++;
    _disposed = true;
    _saveTimer?.cancel();
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _timer?.cancel();
    _discovery?.close();
    _server?.close(force: true);
    store.removeListener(_changed);
    super.dispose();
  }
}

int interfacePriority(NetworkInterface i) {
  if (RegExp(
    r'vpn|virtual|vmware|vbox|vethernet|docker|tun|tap',
    caseSensitive: false,
  ).hasMatch(i.name)) {
    return 2;
  }
  return i.addresses.any(
        (a) =>
            a.address.startsWith('192.168.') ||
            a.address.startsWith('10.') ||
            a.address.startsWith('172.'),
      )
      ? 0
      : 1;
}

String syncError(Object e) {
  if (e is HandshakeException) return '同步失败 · 证书指纹不匹配，请核对电脑并重新扫码';
  if (e is SocketException || e is TimeoutException) {
    return '离线 · 无法连接电脑，请检查同一 Wi-Fi、电脑运行状态与专用网络防火墙';
  }
  if (e is FormatException) return '同步失败 · ${e.message}';
  if (e is HttpException) return '同步失败 · ${e.message}';
  return '同步失败 · 请重试，已有数据保留';
}

Future<void> showSyncDialog(BuildContext context, SyncService sync) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SyncDialog(sync: sync),
    );

class _SyncDialog extends StatefulWidget {
  final SyncService sync;
  const _SyncDialog({required this.sync});
  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  final text = TextEditingController();
  String? error, qr;
  bool working = false;
  SyncService get sync => widget.sync;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = syncError(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (c, _) => PopScope(
      canPop: !working,
      child: AlertDialog(
        title: const Text('设备同步'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sync.status, semanticsLabel: '同步状态：${sync.status}'),
                if (sync.lastSuccess != null)
                  Text(
                    '最近确认同步：${sync.lastSuccess!.toLocal().toString().split('.').first}',
                    style: const TextStyle(fontSize: 12),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '同步自己的全部旅行。两端保留本地数据，断网仍可编辑；连接后整条记录以最新更新为准。准备清单整体属于旅行记录，两端离线同时修改可能互相覆盖。仅保存后的内容参与同步。',
                ),
                const SizedBox(height: 12),
                if (sync.host)
                  OutlinedButton.icon(
                    onPressed: working
                        ? null
                        : () => run(() async {
                            final value = await sync.pairingText();
                            if (mounted) {
                              setState(() {
                                qr = value;
                                text.text = value;
                              });
                            }
                          }),
                    icon: const Icon(Icons.qr_code),
                    label: const Text('连接手机'),
                  ),
                if (qr != null && sync.enabled) ...[
                  Center(
                    child: Semantics(
                      label: '手机扫描此码连接电脑',
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(12),
                        child: QrImageView(
                          data: qr!,
                          size: 250,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const Text('二维码和配对文本包含连接凭据，请勿公开。'),
                ],
                if (!sync.host && Platform.isAndroid)
                  FilledButton.icon(
                    onPressed: working || sync.busy
                        ? null
                        : () async {
                            final value = await Navigator.of(context)
                                .push<String>(
                                  MaterialPageRoute(
                                    builder: (_) => const _PairScanner(),
                                  ),
                                );
                            if (value != null && mounted) {
                              await run(() => sync.pair(value));
                            }
                          },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫描电脑二维码'),
                  ),
                ExpansionTile(
                  title: const Text('文本配对备用入口'),
                  children: [
                    Input('配对文本（请勿公开）', text, lines: 5),
                    if (sync.host)
                      TextButton(
                        onPressed: text.text.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: text.text),
                                );
                                if (c.mounted) notice(c, '已复制，请勿公开配对文本');
                              },
                        child: const Text('复制配对文本'),
                      )
                    else
                      FilledButton(
                        onPressed: working || sync.busy
                            ? null
                            : () => run(() => sync.pair(text.text.trim())),
                        child: const Text('验证配对并同步'),
                      ),
                  ],
                ),
                if (working) const LinearProgressIndicator(),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Theme.of(c).colorScheme.error),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '电脑和手机连接同一 Wi-Fi。电脑保持运行即可，可最小化；手机在前台时自动同步。无需关闭防火墙，仅允许 HowDoI 访问可信专用网络（TCP 47821、UDP 47822）。访客网络、AP 隔离或 VPN 可能阻止连接。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: working ? null : () => run(sync.stop),
            child: const Text('关闭同步'),
          ),
          TextButton(
            onPressed: working
                ? null
                : () => run(() async {
                    await sync.revoke();
                    qr = null;
                    text.clear();
                  }),
            child: const Text('撤销配对'),
          ),
          TextButton(
            onPressed: working || sync.busy
                ? null
                : () => run(() async {
                    if (!sync.enabled) {
                      await sync.start();
                    } else {
                      await sync.tick();
                    }
                  }),
            child: const Text('立即同步 / 重试'),
          ),
          TextButton(
            onPressed: working ? () => sync.stop() : () => Navigator.pop(c),
            child: Text(working ? '取消连接' : '完成'),
          ),
        ],
      ),
    ),
  );
}

class _PairScanner extends StatefulWidget {
  const _PairScanner();
  @override
  State<_PairScanner> createState() => _PairScannerState();
}

class _PairScannerState extends State<_PairScanner> {
  bool handled = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描电脑二维码')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('仅用于扫描 HowDoI 配对二维码；不拍照、不保存图像。'),
          ),
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                if (handled) return;
                final value = capture.barcodes.firstOrNull?.rawValue;
                if (value == null) return;
                try {
                  SyncService.parsePairing(value);
                  handled = true;
                  Navigator.pop(context, value);
                } catch (_) {
                  setState(() => error = '无效二维码，请扫描电脑“连接手机”页面的二维码');
                }
              },
              errorBuilder: (context, error) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('相机不可用或权限被拒绝。可返回使用文本配对；也可在系统应用权限中允许相机后重试。'),
                ),
              ),
            ),
          ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回，使用文本配对'),
          ),
        ],
      ),
    ),
  );
}
