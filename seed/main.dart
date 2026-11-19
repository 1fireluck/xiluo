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

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
        if (bytes.length < 2 * 1024 * 1024) _cache[asset] = bytes;
      } catch (_) {
        try {
          final d = await rootBundle.load('assets/web/index.html');
          bytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
        } catch (_) {}
      }
    }
    final res = req.response;
    if (bytes == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    res.headers.set('Content-Type', _mime(path));
    res.headers.set('Cache-Control', 'no-cache');
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

class _ShellState extends State<Shell> {
  final _host = WebHost();
  final _text = TextEditingController();
  final _focus = FocusNode();
  WebViewController? _web;
  String? _error;
  Timer? _tick;
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _boot();
  }

  @override
  void dispose() {
    _tick?.cancel();
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
        ..addJavaScriptChannel('HeroUI', onMessageReceived: _onHeroUI)
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) => _takeOverInput(),
          onWebResourceError: (e) {
            if (!mounted) return;
            if (e.isForMainFrame ?? true) setState(() => _error = e.description);
          },
        ))
        ..loadRequest(Uri.parse('${_host.origin}/?v=${DateTime.now().millisecondsSinceEpoch}'));
      if (!mounted) return;
      setState(() => _web = c);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _takeOverInput() async {
    final c = _web;
    if (c == null) return;
    try {
      await c.runJavaScript('window.heroInput&&window.heroInput.hide();');
    } catch (_) {}
    _tick?.cancel();
    try {
      await c.runJavaScript('window.heroInput&&window.heroInput.watch();');
    } catch (_) {}
  }

  void _onHeroUI(JavaScriptMessage m) {
    if (!mounted) return;
    final open = m.message == '0';
    if (open != _drawerOpen) setState(() => _drawerOpen = open);
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    final c = _web;
    if (t.isEmpty || c == null) return;
    _text.clear();
    try {
      await c.runJavaScript('window.heroInput&&window.heroInput.send(${jsonEncode(t)});');
    } catch (_) {}
    _focus.requestFocus();
    await _takeOverInput();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: true,
        child: Column(
          children: [
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('页面没起来：$_error',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
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
            AnimatedPadding(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(
                  left: _drawerOpen
                      ? MediaQuery.of(context).size.width * 0.78
                      : 0),
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

class _Composer extends StatelessWidget {
  const _Composer(
      {required this.controller, required this.focus, required this.onSend});
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final has = controller.text.trim().isNotEmpty;
    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Container(
        decoration: BoxDecoration(
          color: _box,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
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
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 6),
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
