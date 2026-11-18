import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const Color kBg = Color(0xFF0B0B0D);
const Color kFg = Color(0xFFF2F0EC);
const Color kDim = Color(0xFF8A8A8E);
const Color kRed = Color(0xFFB3121B);
const Color kGold = Color(0xFFC9A227);
const Color kMe = Color(0xFF303136);

void main() {
  runApp(const XiluoApp());
}

class Cfg {
  static String base = 'http://192.168.71.7:8765';

  static File get _file {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return File('$home/Documents/xiluo.json');
  }

  static Future<void> load() async {
    try {
      if (await _file.exists()) {
        final dynamic j = jsonDecode(await _file.readAsString());
        if (j is Map && j['base'] is String) {
          final String b = j['base'];
          if (b.isNotEmpty) base = b;
        }
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode({'base': base}));
    } catch (_) {}
  }
}

class Msg {
  String role;
  String text;
  Msg(this.role, this.text);
}

class XiluoApp extends StatelessWidget {
  const XiluoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '希罗',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        canvasColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kRed, surface: kBg),
        fontFamily: 'PingFang SC',
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final List<Msg> _msgs = <Msg>[];
  final TextEditingController _ctl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  bool _busy = false;
  bool _ready = false;
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Cfg.load();
    await _loadHistory();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _loadHistory() async {
    HttpClient? c;
    try {
      c = HttpClient();
      final HttpClientRequest req = await c.getUrl(Uri.parse('${Cfg.base}/history'));
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      final dynamic j = jsonDecode(body);
      final List<dynamic> list = (j is Map && j['history'] is List) ? j['history'] as List<dynamic> : <dynamic>[];
      final List<Msg> got = <Msg>[];
      for (final dynamic e in list) {
        if (e is! Map) continue;
        final String role = (e['role'] ?? 'assistant').toString();
        final String text = (e['content'] ?? '').toString();
        if (text.isEmpty) continue;
        got.add(Msg(role == 'user' ? 'user' : 'assistant', text));
      }
      setState(() {
        _msgs
          ..clear()
          ..addAll(got);
        _hint = '';
      });
      _toBottom();
    } catch (e) {
      setState(() => _hint = '连不上她（${Cfg.base}）· 点标题改地址');
    } finally {
      c?.close(force: true);
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final String text = _ctl.text.trim();
    if (text.isEmpty || _busy) return;
    _ctl.clear();
    setState(() {
      _msgs.add(Msg('user', text));
      _msgs.add(Msg('assistant', ''));
      _busy = true;
      _hint = '';
    });
    _toBottom();
    HttpClient? c;
    try {
      c = HttpClient();
      final HttpClientRequest req = await c.postUrl(Uri.parse('${Cfg.base}/chat_stream'));
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.add(utf8.encode(jsonEncode({'message': text})));
      final HttpClientResponse res = await req.close();
      String buf = '';
      await for (final String chunk in res.transform(utf8.decoder)) {
        buf += chunk;
        while (true) {
          final int i = buf.indexOf('\n\n');
          if (i < 0) break;
          final String line = buf.substring(0, i);
          buf = buf.substring(i + 2);
          if (!line.startsWith('data: ')) continue;
          final String p = line.substring(6).trim();
          if (p == '[DONE]' || p.isEmpty) continue;
          try {
            final dynamic j = jsonDecode(p);
            if (j is Map && j['t'] is String) {
              final String t = j['t'];
              if (t.isEmpty) continue;
              setState(() => _msgs.last.text += t);
              _toBottom();
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      setState(() {
        if (_msgs.isNotEmpty && _msgs.last.text.isEmpty) {
          _msgs.last.text = '（她没接上。看看电脑上的希罗开着没有）';
        }
      });
    } finally {
      c?.close(force: true);
      if (mounted) setState(() => _busy = false);
      _toBottom();
    }
  }

  Future<void> _editServer() async {
    final TextEditingController t = TextEditingController(text: Cfg.base);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151517),
        title: const Text('她在哪台电脑上', style: TextStyle(color: kFg, fontSize: 16)),
        content: TextField(
          controller: t,
          style: const TextStyle(color: kFg),
          decoration: const InputDecoration(
            hintText: 'http://192.168.71.7:8765',
            hintStyle: TextStyle(color: kDim),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('算了')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('就这样')),
        ],
      ),
    );
    if (ok == true) {
      Cfg.base = t.text.trim();
      await Cfg.save();
      await _loadHistory();
    }
  }

  Widget _bubble(Msg m) {
    final bool me = m.role == 'user';
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: me ? 44 : 0,
          right: me ? 0 : 44,
          top: 6,
          bottom: 6,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: me ? kMe : Colors.transparent,
          borderRadius: BorderRadius.circular(me ? 14 : 4),
        ),
        child: SelectableText(
          m.text.isEmpty ? '…' : m.text,
          style: TextStyle(
            color: m.text.isEmpty ? kDim : kFg,
            fontSize: 15.5,
            height: 1.75,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF1E1E20), width: 1)),
              ),
              child: Row(
                children: <Widget>[
                  const Text('❀', style: TextStyle(color: kRed, fontSize: 17)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _editServer,
                    child: const Text('希罗',
                        style: TextStyle(color: kGold, fontSize: 18, letterSpacing: 2)),
                  ),
                  const Spacer(),
                  if (_busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.4, color: kRed),
                    ),
                ],
              ),
            ),
            if (_hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(_hint, style: const TextStyle(color: kDim, fontSize: 12.5)),
              ),
            Expanded(
              child: !_ready
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: kRed),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtl,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      itemCount: _msgs.length,
                      itemBuilder: (BuildContext ctx, int i) => _bubble(_msgs[i]),
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFF1E1E20), width: 1)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2D2D2D),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: TextField(
                        controller: _ctl,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(color: kFg, fontSize: 15),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '和希罗说点什么…',
                          hintStyle: TextStyle(color: kDim),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _send,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(color: kRed, shape: BoxShape.circle),
                      child: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
