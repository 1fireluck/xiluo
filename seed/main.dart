import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// 设计令牌：取自真实界面的实测值（不靠眼睛估）
// ---------------------------------------------------------------------------
class T {
  static const bg = Color(0xFF151517);
  static const sideBg = Color(0xFF1B1B1C);
  static const selected = Color(0xFF353638);
  static const bubble = Color(0xFF2C2C2E);
  static const text = Color(0xFFF9FAFB);
  static const sub = Color(0xFFADB2B8);
  static const accent = Color(0xFF4D6BFE);
  static const line = Color(0x0FFFFFFF);

  static const bubbleRadius = 22.0;
  static const inputRadius = 24.0;
  static const bodySize = 16.0;
  static const bodyHeight = 28 / 16;
  static const userHeight = 24 / 16;
}

void main() {
  runApp(const HeroApp());
}

class HeroApp extends StatelessWidget {
  const HeroApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hero',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: T.bg,
        canvasColor: T.bg,
        fontFamily: 'PingFang SC',
        colorScheme: const ColorScheme.dark(
          primary: T.accent,
          surface: T.bg,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// 数据
// ---------------------------------------------------------------------------
class Msg {
  Msg({required this.role, required this.text, this.reasoning = ''});
  String role; // user | assistant
  String text;
  String reasoning;
  bool streaming = false;

  Map<String, dynamic> toJson() =>
      {'role': role, 'text': text, 'reasoning': reasoning};
  static Msg fromJson(Map<String, dynamic> j) => Msg(
        role: j['role'] as String? ?? 'assistant',
        text: j['text'] as String? ?? '',
        reasoning: j['reasoning'] as String? ?? '',
      );
}

class Conv {
  Conv({required this.id, this.title = '新的对话'});
  String id;
  String title;
  List<Msg> msgs = [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'msgs': msgs.map((m) => m.toJson()).toList(),
      };
  static Conv fromJson(Map<String, dynamic> j) {
    final c = Conv(id: j['id'] as String, title: j['title'] as String? ?? '新的对话');
    c.msgs = (j['msgs'] as List? ?? [])
        .map((e) => Msg.fromJson(e as Map<String, dynamic>))
        .toList();
    return c;
  }
}

class MemoryFact {
  MemoryFact(this.text, this.at);
  String text;
  int at;
  Map<String, dynamic> toJson() => {'text': text, 'at': at};
  static MemoryFact fromJson(Map<String, dynamic> j) =>
      MemoryFact(j['text'] as String, (j['at'] as num).toInt());
}

// ---------------------------------------------------------------------------
// 本地存储（不引第三方包：iOS 上 HOME 就是应用容器）
// ---------------------------------------------------------------------------
class Store {
  static Directory get _dir {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final d = Directory('$home/Documents/hero');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static File get _file => File('${_dir.path}/state.json');

  static Map<String, dynamic> load() {
    try {
      if (!_file.existsSync()) return {};
      final raw = _file.readAsStringSync();
      if (raw.trim().isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static void save(Map<String, dynamic> data) {
    try {
      _file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 主界面
// ---------------------------------------------------------------------------
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focus = FocusNode();

  List<Conv> convs = [];
  String currentId = '';
  String apiKey = '';
  bool deepThink = false;
  bool smartSearch = false;
  bool streaming = false;
  List<MemoryFact> memories = [];
  String _searchMarker = '';

  Conv get current =>
      convs.firstWhere((c) => c.id == currentId, orElse: () => convs.first);

  @override
  void initState() {
    super.initState();
    _restore();
  }

  void _restore() {
    final s = Store.load();
    apiKey = s['apiKey'] as String? ?? '';
    deepThink = s['deepThink'] as bool? ?? false;
    smartSearch = s['smartSearch'] as bool? ?? false;
    memories = (s['memories'] as List? ?? [])
        .map((e) => MemoryFact.fromJson(e as Map<String, dynamic>))
        .toList();
    convs = (s['convs'] as List? ?? [])
        .map((e) => Conv.fromJson(e as Map<String, dynamic>))
        .toList();
    if (convs.isEmpty) convs = [Conv(id: _newId())];
    currentId = s['currentId'] as String? ?? convs.first.id;
    if (!convs.any((c) => c.id == currentId)) currentId = convs.first.id;
    setState(() {});
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  void _persist() {
    Store.save({
      'apiKey': apiKey,
      'deepThink': deepThink,
      'smartSearch': smartSearch,
      'currentId': currentId,
      'convs': convs.map((c) => c.toJson()).toList(),
      'memories': memories.map((m) => m.toJson()).toList(),
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 发送
  Future<void> send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || streaming) return;
    if (apiKey.isEmpty) {
      _toast('先到设置里填上 API Key');
      return;
    }
    _inputCtrl.clear();
    final c = current;
    if (c.msgs.isEmpty) c.title = text.length > 18 ? text.substring(0, 18) : text;
    setState(() {
      c.msgs.add(Msg(role: 'user', text: text));
      c.msgs.add(Msg(role: 'assistant', text: '')..streaming = true);
      streaming = true;
    });
    _persist();
    _scrollToEnd();

    final reply = c.msgs.last;
    try {
      await _callApi(c, reply);
    } catch (e) {
      reply.text = '（连接失败：$e）';
      reply.streaming = false;
      streaming = false;
      setState(() {});
      _persist();
      return;
    }
    reply.streaming = false;
    streaming = false;
    setState(() {});
    _persist();
    _maybeLearn(c);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent + 400,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  // ------------------------------------------------------------------ API
  List<Map<String, String>> _buildMessages(Conv c) {
    final out = <Map<String, String>>[];
    // 记忆：只当事实，不写「怎么说」
    if (memories.isNotEmpty) {
      final facts = memories.map((m) => '- ${m.text}').join('\n');
      out.add({
        'role': 'system',
        'content': '以下是用户过往提过的、可复用的背景信息（只当事实参考，不必复述，也不要因此改变你的说话风格）：\n$facts',
      });
    }
    for (final m in c.msgs) {
      if (m.role == 'assistant' && m.text.trim().isEmpty) continue;
      out.add({'role': m.role, 'content': m.text});
    }
    return out;
  }

  Future<void> _callApi(Conv c, Msg reply) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(Uri.parse('https://api.deepseek.com/chat/completions'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer $apiKey');
      final body = jsonEncode({
        'model': deepThink ? 'deepseek-reasoner' : 'deepseek-chat',
        'messages': _buildMessages(c),
        'stream': true,
      });
      req.add(utf8.encode(body));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        final t = await resp.transform(utf8.decoder).join();
        throw Exception('HTTP ${resp.statusCode} ${t.length > 120 ? t.substring(0, 120) : t}');
      }
      final buf = StringBuffer();
      var pending = '';
      await for (final chunk in resp.transform(utf8.decoder)) {
        pending += chunk;
        final lines = pending.split('\n');
        pending = lines.removeLast();
        for (final line in lines) {
          final l = line.trim();
          if (l.isEmpty || !l.startsWith('data:')) continue;
          final payload = l.substring(5).trim();
          if (payload == '[DONE]') continue;
          try {
            final j = jsonDecode(payload) as Map<String, dynamic>;
            final delta = (j['choices'] as List?)?.first?['delta'] as Map?;
            if (delta == null) continue;
            final r = delta['reasoning_content'] as String?;
            final t = delta['content'] as String?;
            if (r != null && r.isNotEmpty) reply.reasoning += r;
            if (t != null && t.isNotEmpty) buf.write(t);
            if ((r ?? t) != null) {
              reply.text = buf.toString();
              if (mounted) setState(() {});
              if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
            }
          } catch (_) {}
        }
      }
      reply.text = buf.toString();
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------------ 记忆
  Future<void> _maybeLearn(Conv c) async {
    // 每 4 轮学一次，且只在有用户消息时
    final userCount = c.msgs.where((m) => m.role == 'user').length;
    if (userCount == 0 || userCount % 4 != 0) return;
    try {
      final recent = c.msgs.length > 12 ? c.msgs.sublist(c.msgs.length - 12) : c.msgs;
      final convo = recent.map((m) => '${m.role == 'user' ? '用户' : '助手'}：${m.text}').join('\n');
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('https://api.deepseek.com/chat/completions'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer $apiKey');
      req.add(utf8.encode(jsonEncode({
        'model': 'deepseek-chat',
        'messages': [
          {
            'role': 'system',
            'content': '从下面的对话里，抽取「关于用户本人的、以后还能用得上的事实」（身份、喜好、经历、约定、重要的人）。'
                '只输出事实，每行一条，以「- 」开头，最多 5 条。不要写对话摘要，不要写语气建议。没有就输出空。'
          },
          {'role': 'user', 'content': convo},
        ],
        'stream': false,
      })));
      final resp = await req.close();
      final txt = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final j = jsonDecode(txt) as Map<String, dynamic>;
      final content = ((j['choices'] as List).first['message']['content'] as String).trim();
      if (content.isEmpty) return;
      final lines = content
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.startsWith('- '))
          .map((e) => e.substring(2).trim())
          .where((e) => e.length > 1)
          .toList();
      for (final l in lines) {
        final dup = memories.any((m) => m.text == l);
        if (!dup) memories.add(MemoryFact(l, DateTime.now().millisecondsSinceEpoch));
      }
      if (memories.length > 200) memories = memories.sublist(memories.length - 200);
      _persist();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ------------------------------------------------------------------ UI
  void _toast(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s, style: const TextStyle(color: T.text)),
      backgroundColor: T.bubble,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _newConv() {
    final c = Conv(id: _newId());
    setState(() {
      convs.insert(0, c);
      currentId = c.id;
    });
    _persist();
    Navigator.of(context).maybePop();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(child: _messages()),
            _inputBar(),
            const Padding(
              padding: EdgeInsets.only(top: 6, bottom: 10),
              child: Text('内容由 AI 生成，请仔细甄别',
                  style: TextStyle(fontSize: 13, color: T.sub, height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final empty = current.msgs.isEmpty;
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          const SizedBox(width: 6),
          _iconBtn(Icons.menu_rounded, () => _scaffoldKey.currentState?.openDrawer()),
          const SizedBox(width: 4),
          Expanded(
            child: GestureDetector(
              onTap: _renameDialog,
              child: Text(
                empty ? 'hero' : current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, color: T.text, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          _iconBtn(Icons.add_rounded, _newConv),
          _iconBtn(Icons.more_horiz_rounded, _sheet),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData i, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(i, size: 20, color: T.text),
        ),
      );

  Widget _messages() {
    final msgs = current.msgs;
    if (msgs.isEmpty) return _welcome();
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: msgs.length,
      itemBuilder: (ctx, i) {
        final m = msgs[i];
        return m.role == 'user' ? _userBubble(m) : _assistantBlock(m, i == msgs.length - 1);
      },
    );
  }

  Widget _welcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text('❀',
                style: TextStyle(fontSize: 44, color: Color(0xFFBE1A24))),
            SizedBox(height: 16),
            Text('嗨！今天想聊些什么？',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w600, color: T.text, height: 32 / 24)),
          ],
        ),
      ),
    );
  }

  Widget _userBubble(Msg m) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: T.bubble,
              borderRadius: BorderRadius.all(Radius.circular(T.bubbleRadius)),
            ),
            child: Text(m.text,
                style: const TextStyle(
                    fontSize: T.bodySize, height: T.userHeight, color: T.text)),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _miniIcon(Icons.copy_rounded, () {
                Clipboard.setData(ClipboardData(text: m.text));
                _toast('已复制');
              }),
              _miniIcon(Icons.edit_outlined, () {
                _inputCtrl.text = m.text;
                _focus.requestFocus();
              }),
              const SizedBox(width: 6),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniIcon(IconData i, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(i, size: 16, color: T.sub),
        ),
      );

  Widget _assistantBlock(Msg m, bool last) {
    final showReasoning = m.reasoning.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showReasoning) _reasoningBox(m),
          SelectableText.rich(
            _rich(m.text),
            style: const TextStyle(
                fontSize: T.bodySize, height: T.bodyHeight, color: T.text),
          ),
          if (m.streaming)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: T.sub)),
            ),
          if (!m.streaming && last)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  _miniIcon(Icons.copy_rounded, () {
                    Clipboard.setData(ClipboardData(text: m.text));
                    _toast('已复制');
                  }),
                  _miniIcon(Icons.refresh_rounded, _regenerate),
                  _miniIcon(Icons.thumb_up_alt_outlined, () => _toast('已赞')),
                  _miniIcon(Icons.thumb_down_alt_outlined, () => _toast('已反馈')),
                  _miniIcon(Icons.volume_up_outlined, () => _toast('朗读稍后做')),
                  _miniIcon(Icons.ios_share_rounded, () {
                    Clipboard.setData(ClipboardData(text: m.text));
                    _toast('已复制，可粘贴分享');
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _reasoningBox(Msg m) {
    final open = m.streaming;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: T.line),
      ),
      child: ExpansionTile(
        initiallyExpanded: open,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        iconColor: T.sub,
        collapsedIconColor: T.sub,
        title: Text('已深度思考',
            style: const TextStyle(fontSize: 13, color: T.sub, height: 1.4)),
        children: [
          Text(m.reasoning,
              style: const TextStyle(fontSize: 13, height: 1.6, color: T.sub)),
        ],
      ),
    );
  }

  Future<void> _regenerate() async {
    final c = current;
    if (c.msgs.isEmpty || streaming) return;
    // 去掉最后一条助手回复
    while (c.msgs.isNotEmpty && c.msgs.last.role == 'assistant') {
      c.msgs.removeLast();
    }
    if (c.msgs.isEmpty) return;
    final lastUser = c.msgs.removeLast();
    _inputCtrl.text = lastUser.text;
    setState(() {});
    await send();
  }

  TextSpan _rich(String s) {
    // 极简 markdown：```代码块``` / **粗体** / 行内 `代码` / 标题 / 列表
    final spans = <InlineSpan>[];
    final blocks = s.split('```');
    for (var i = 0; i < blocks.length; i++) {
      final isCode = i.isOdd;
      final b = blocks[i];
      if (isCode) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: const Color(0xFF1E1E20), borderRadius: BorderRadius.circular(10)),
            child: Text(b.trim(),
                style: const TextStyle(
                    fontFamily: 'Menlo', fontSize: 13, height: 1.5, color: T.text)),
          ),
        ));
        continue;
      }
      final lines = b.split('\n');
      for (var k = 0; k < lines.length; k++) {
        final line = lines[k];
        if (line.trim().isEmpty) {
          spans.add(const TextSpan(text: '\n'));
          continue;
        }
        final isHead = RegExp(r'^#{1,3} ').hasMatch(line);
        final plain = isHead ? line.replaceFirst(RegExp(r'^#{1,3} '), '') : line;
        final bold = isHead;
        // 行内 `code`
        final parts = plain.split('`');
        for (var p = 0; p < parts.length; p++) {
          final isInlineCode = p.isOdd;
          final txt = parts[p];
          if (txt.isEmpty) continue;
          spans.add(TextSpan(
            text: p == parts.length - 1 ? '$txt\n' : txt,
            style: isInlineCode
                ? const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 14,
                    backgroundColor: Color(0xFF1E1E20))
                : (bold
                    ? const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600, height: 1.6)
                    : null),
          ));
        }
      }
    }
    return TextSpan(children: spans);
  }

  // ------------------------------------------------------------------ 输入
  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: T.bubble,
          borderRadius: BorderRadius.circular(T.inputRadius),
          border: Border.all(color: const Color(0x0FFFFFFF)),
        ),
        child: Column(
          children: [
            TextField(
              controller: _inputCtrl,
              focusNode: _focus,
              maxLines: 6,
              minLines: 1,
              style: const TextStyle(fontSize: T.bodySize, height: 24 / 16, color: T.text),
              cursorColor: T.accent,
              decoration: const InputDecoration(
                hintText: '给 hero 发送消息',
                hintStyle: TextStyle(color: Color(0xFF8A8F98), fontSize: 16),
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              ),
              textInputAction: TextInputAction.newline,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                children: [
                  _pill(Icons.psychology_outlined, '深度思考', deepThink,
                      () => setState(() { deepThink = !deepThink; _persist(); })),
                  const SizedBox(width: 8),
                  _pill(Icons.language_rounded, '智能搜索', smartSearch,
                      () => setState(() { smartSearch = !smartSearch; _persist(); })),
                  const Spacer(),
                  _iconBtn(Icons.attach_file_rounded, () => _toast('附件稍后做')),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: send,
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: T.accent,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(Icons.arrow_upward_rounded,
                          size: 19, color: Colors.white),
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

  Widget _pill(IconData icon, String label, bool on, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF3A3A3C) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: on ? T.accent : T.text),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: on ? T.text : T.text)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 抽屉
  Widget _drawer() {
    return Drawer(
      backgroundColor: T.sideBg,
      width: MediaQuery.of(context).size.width * 0.82,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  const Text('hero',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600, color: T.text)),
                  const Spacer(),
                  _iconBtn(Icons.search_rounded, () => _toast('搜索稍后做')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: InkWell(
                onTap: _newConv,
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2C),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Center(
                    child: Text('开启新对话',
                        style: TextStyle(fontSize: 15, color: T.text)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: convs.length,
                itemBuilder: (ctx, i) {
                  final c = convs[i];
                  final sel = c.id == currentId;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() => currentId = c.id);
                        _persist();
                        Navigator.of(context).maybePop();
                      },
                      onLongPress: () => _convMenu(c),
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: sel ? T.selected : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, color: T.text)),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Color(0x14FFFFFF), height: 1),
            ListTile(
              leading: const Icon(Icons.tune_rounded, size: 20, color: T.text),
              title: const Text('设置',
                  style: TextStyle(fontSize: 14, color: T.text)),
              onTap: () {
                Navigator.of(context).maybePop();
                _settings();
              },
            ),
            ListTile(
              leading: const Icon(Icons.memory_rounded, size: 20, color: T.text),
              title: Text('记忆（${memories.length}）',
                  style: const TextStyle(fontSize: 14, color: T.text)),
              onTap: () {
                Navigator.of(context).maybePop();
                _memorySheet();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  void _convMenu(Conv c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E20),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('重命名', style: TextStyle(color: T.text)),
              onTap: () {
                Navigator.pop(context);
                _renameDialog(c);
              },
            ),
            ListTile(
              title: const Text('删除', style: TextStyle(color: Color(0xFFFF6B6B))),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  convs.removeWhere((x) => x.id == c.id);
                  if (convs.isEmpty) convs = [Conv(id: _newId())];
                  if (currentId == c.id) currentId = convs.first.id;
                });
                _persist();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _renameDialog([Conv? c]) {
    final conv = c ?? current;
    final ctrl = TextEditingController(text: conv.title);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E20),
        title: const Text('标题', style: TextStyle(fontSize: 16, color: T.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: T.text),
          decoration: const InputDecoration(hintText: '给这段对话起个名字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () {
              setState(() => conv.title = ctrl.text.trim().isEmpty ? conv.title : ctrl.text.trim());
              _persist();
              Navigator.pop(context);
            },
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _sheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E20),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tune_rounded, color: T.text),
              title: const Text('设置', style: TextStyle(color: T.text)),
              onTap: () {
                Navigator.pop(context);
                _settings();
              },
            ),
            ListTile(
              leading: const Icon(Icons.memory_rounded, color: T.text),
              title: Text('记忆（${memories.length}）', style: const TextStyle(color: T.text)),
              onTap: () {
                Navigator.pop(context);
                _memorySheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_rounded, color: Color(0xFFFF6B6B)),
              title: const Text('清空当前对话', style: TextStyle(color: Color(0xFFFF6B6B))),
              onTap: () {
                Navigator.pop(context);
                setState(() => current.msgs.clear());
                _persist();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _settings() {
    final ctrl = TextEditingController(text: apiKey);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E20),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            left: 20, right: 20, top: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('设置', style: TextStyle(fontSize: 17, color: T.text)),
            const SizedBox(height: 16),
            const Text('API Key（platform.deepseek.com 里生成）',
                style: TextStyle(fontSize: 13, color: T.sub)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: T.text),
              decoration: InputDecoration(
                hintText: 'sk-...',
                filled: true,
                fillColor: T.bubble,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: T.accent),
                onPressed: () {
                  setState(() => apiKey = ctrl.text.trim());
                  _persist();
                  Navigator.pop(context);
                  _toast('已保存');
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _memorySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E20),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('长期记忆', style: TextStyle(fontSize: 17, color: T.text)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setState(() => memories.clear());
                      _persist();
                      Navigator.pop(context);
                    },
                    child: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text('只记事实，不会改变她说话的方式',
                  style: TextStyle(fontSize: 12, color: T.sub)),
              const SizedBox(height: 12),
              Flexible(
                child: memories.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('还没有记住什么', style: TextStyle(color: T.sub)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: memories.length,
                        itemBuilder: (ctx, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Text('· ${memories[i].text}',
                              style: const TextStyle(
                                  fontSize: 14, height: 1.6, color: T.text)),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
