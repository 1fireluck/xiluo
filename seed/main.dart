import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _bg = Color(0xFF151517);
const _box = Color(0xFF2C2C2E);
const _fg = Color(0xFFF9FAFB);
const _hint = Color(0xFF8A8A8E);
const _accent = Color(0xFF4D6BFE);

/// 把打包进 App 的官方 chat-demo 静态站点，用本机回环 HTTP 服务跑起来。
/// 这样页面有真正的 http 源，localStorage / IndexedDB 才能正常工作。
class WebHost {
  HttpServer? _server;
  final Map<String, Uint8List> _cache = {};

  String get origin => 'http://127.0.0.1:${_server!.port}';

  /// 固定端口：IndexedDB / localStorage 按「源」（协议+主机+端口）隔离，
  /// 端口一变就等于换了一个网站，之前存进去的对话全都看不见。
  static const int _preferredPort = 8931;

  Future<void> start() async {
    for (var p = _preferredPort; p < _preferredPort + 4; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        break;
      } catch (_) {}
    }
    _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    var path = req.uri.path;
    if (path == '/' || path.isEmpty) path = '/index.html';
    final asset = 'assets/web$path';
    Uint8List? bytes = _cache[asset];
    if (bytes == null) {
      try {
        final d = await rootBundle.load(asset);
        bytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
        _cache[asset] = bytes;
      } catch (_) {
        if (!path.contains('.')) {
          try {
            final d = await rootBundle.load('assets/web/index.html');
            bytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
          } catch (_) {}
        }
      }
    }
    final res = req.response;
    if (bytes == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    res.headers.set('Content-Type', _mime(path));
    if (path.endsWith('.html')) {
      res.headers.set('Cache-Control', 'no-cache');
    } else {
      res.headers.set('Cache-Control', 'public, max-age=31536000, immutable');
    }
    res.headers.contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  String _mime(String p) {
    if (p.endsWith('.html')) return 'text/html; charset=utf-8';
    if (p.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (p.endsWith('.css')) return 'text/css; charset=utf-8';
    if (p.endsWith('.json')) return 'application/json; charset=utf-8';
    if (p.endsWith('.svg')) return 'image/svg+xml';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.woff2')) return 'font/woff2';
    if (p.endsWith('.woff')) return 'font/woff';
    if (p.endsWith('.ttf')) return 'font/ttf';
    if (p.endsWith('.wasm')) return 'application/wasm';
    if (p.endsWith('.map')) return 'application/json';
    return 'application/octet-stream';
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const HeroApp());
}

class HeroApp extends StatelessWidget {
  const HeroApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'hero',
        theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: _bg,
            canvasColor: _bg),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with SingleTickerProviderStateMixin {
  final _host = WebHost();
  final _text = TextEditingController();
  final _focus = FocusNode();
  WebViewController? _web;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];
  late final AnimationController _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 120), value: 0);

  bool get _open => _anim.value > 0.02;
  bool _modalOpen = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _boot();
  }

  @override
  void dispose() {
    _anim.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await _host.start();
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(_bg)
        ..addJavaScriptChannel('HeroUI', onMessageReceived: _onJs)
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) {
            _web?.runJavaScript('window.heroMemory&&window.heroMemory.watch&&window.heroMemory.watch();');
          },
          onPageStarted: (_) {
            if (mounted && _error != null) setState(() => _error = null);
          },
          onWebResourceError: (e) {
            if (!mounted) return;
            if (!(e.isForMainFrame ?? false)) return;
            if (e.errorCode == -999) return;
            final u = e.url ?? '';
            if (u.isNotEmpty && !u.startsWith(_host.origin)) return;
            setState(() => _error = e.description);
          },
        ))
        ..loadRequest(Uri.parse('${_host.origin}/?v=${DateTime.now().millisecondsSinceEpoch}'));
      if (!mounted) return;
      setState(() => _web = c);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onJs(JavaScriptMessage m) {
    final s = m.message;
    if (s.startsWith('M:')) {
      final open = s.substring(2) == '0';
      if (mounted && open != _modalOpen) setState(() => _modalOpen = open);
      return;
    }
    if (s.startsWith('DONE:')) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('搬完了（' + s.substring(5) + ' 个），重开一次 App 就能看到'), duration: const Duration(seconds: 6)),
      );
      return;
    }
    if (s.startsWith('SEED:')) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('搬进来 ' + s.substring(5)), duration: const Duration(seconds: 2)),
      );
      return;
    }
    if (s.startsWith('S:')) {
      try {
        final list = jsonDecode(s.substring(2)) as List;
        if (!mounted) return;
        setState(() => _sessions =
            list.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      } catch (_) {}
    }
  }

  void _toggle() {
    if (_open) {
      _anim.reverse();
    } else {
      _anim.forward();
      _web?.runJavaScript('window.heroDrawer&&window.heroDrawer.scan();');
    }
    _focus.unfocus();
  }

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    _web?.runJavaScript('window.heroInput&&window.heroInput.send(${jsonEncode(t)});');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('页面没起来：$_error',
                          style: const TextStyle(color: Colors.white70, fontSize: 14)),
                    ))
                  : (_web == null
                      ? const Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white38)))
                      : WebViewWidget(controller: _web!)),
            ),
            if (!_modalOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _Composer(
                  controller: _text,
                  focus: _focus,
                  onSend: _send,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Drawer extends StatelessWidget {
  const _Drawer(
      {required this.width,
      required this.sessions,
      required this.onNew,
      required this.onOpen,
      required this.onSettings});
  final double width;
  final List<Map<String, dynamic>> sessions;
  final VoidCallback onNew;
  final void Function(int) onOpen;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: const Color(0xFF1B1B1C),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: InkWell(
              onTap: onNew,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF353638),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_circle_outline, size: 18, color: _fg),
                    SizedBox(width: 8),
                    Text('开启新对话',
                        style: TextStyle(color: _fg, fontSize: 15)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: sessions.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: sessions.length,
                    itemBuilder: (ctx, i) {
                      final t = (sessions[i]['t'] ?? '').toString();
                      return InkWell(
                        onTap: () => onOpen(i),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 11),
                          child: Text(t,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: _fg, fontSize: 15)),
                        ),
                      );
                    },
                  ),
          ),
          InkWell(
            onTap: onSettings,
            child: const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 22),
              child: Row(children: [
                Icon(Icons.settings_outlined, size: 20, color: _fg),
                SizedBox(width: 10),
                Text('设置', style: TextStyle(color: _fg, fontSize: 16)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer(
      {required this.controller,
      required this.focus,
      required this.onSend});
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final has = controller.text.trim().isNotEmpty;
    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Container(
        decoration: BoxDecoration(
          color: _box,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [

            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                minLines: 1,
                maxLines: 5,
                cursorColor: _accent,
                style: const TextStyle(color: _fg, fontSize: 16, height: 1.5),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '发消息',
                  hintStyle: TextStyle(color: _hint, fontSize: 16),
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 5, left: 4),
              child: GestureDetector(
                onTap: has ? onSend : null,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: has ? _accent : _box,
                    shape: BoxShape.circle,
                    border: has
                        ? null
                        : Border.all(color: Colors.white.withOpacity(0.10)),
                  ),
                  child: Icon(Icons.arrow_upward,
                      size: 19, color: has ? Colors.white : _hint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}