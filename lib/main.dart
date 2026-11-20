import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// ================= 设计令牌（实测值） =================
class C {
  static const bg = Color(0xFF151517);
  static const side = Color(0xFF1B1B1C);
  static const selected = Color(0xFF353638);
  static const bubble = Color(0xFF2C2C2E);
  static const text = Color(0xFFF9FAFB);
  static const sub = Color(0xFFADB2B8);
  static const accent = Color(0xFF4D6BFE);
  static const line = Color(0xFF282829);
  static const white06 = Color(0x0FFFFFFF);
  static const white12 = Color(0x1FFFFFFF);
  static const code = Color(0xFF1E1E20);
}

// 默认 API Key（主人本机已有；可在设置里改）
const String kDefaultKey = String.fromEnvironment('HERO_KEY', defaultValue: '');

// ================= 数据模型 =================
class Msg {
  String role; // user / assistant
  String text;
  String thinking;
  String draft = '';        // 还没发出去的修改，退出再点要保留
  bool touched = false;     // 这条被重新生成过
  List<String> alts = [];   // 重新生成的多个版本（text 是当前显示的那个）
  int cur = 0;              // 当前在第几个版本
  String altText = '';      // 改过这条之后，另一条分支里我说的那句话
  String altReply = '';     // 同一分支里她那句回复
  int altCur = 0;           // 现在显示的是第几条分支（0=改后 1=改前）
  Msg(this.role, this.text, {this.thinking = ''});
  Map<String, dynamic> toJson() =>
      {
        'r': role,
        't': text,
        'k': thinking,
        'alts': alts,
        'cur': cur,
        'at': altText,
        'ar': altReply,
        'ac': altCur,
      };
  static Msg fromJson(Map<String, dynamic> j) => Msg(
        j['r'] ?? 'user',
        j['t'] ?? '',
        thinking: j['k'] ?? '',
      )
        ..alts = ((j['alts'] as List?) ?? []).map((e) => '$e').toList()
        ..cur = (j['cur'] as int?) ?? 0
        ..altText = j['at'] ?? ''
        ..altReply = j['ar'] ?? ''
        ..altCur = (j['ac'] as int?) ?? 0;
}

class Session {
  String id;
  String title;
  int created;
  String memBlock;
  List<Msg> msgs;
  Session(this.id, this.title, this.created, [List<Msg>? m, this.memBlock = '']) : msgs = m ?? [];
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'created': created,
        'mem': memBlock,
        'msgs': msgs.map((e) => e.toJson()).toList(),
      };
  static Session fromJson(Map<String, dynamic> j) => Session(
        j['id'],
        j['title'] ?? '聊天......',
        j['created'] ?? 0,
        (j['msgs'] as List? ?? []).map((e) => Msg.fromJson(e)).toList(),
        j['mem'] ?? '',
      );
}

class Store {
  List<Session> sessions = [];
  List<Msg> history = [];
  List<String> voice = [];
  List<Msg> archive = [];
  bool archiveLoaded = false;
  List<String> memory = [];
  List<Map<String, String>> days = []; // {d, s}
  String key = kDefaultKey;
  String model = 'deepseek-chat';
  bool thinking = false;
  String curId = '';
  int resetAt = 0;   // 重置到原对话结尾用的标记（一次生效）

  File? _file;

  Future<void> init() async {
    if (kIsWeb) { _seedMemoryless(); return; }
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/hero');
    if (!await d.exists()) await d.create(recursive: true);
    _file = File('${d.path}/store.json');
    if (await _file!.exists()) {
      try {
        final j = jsonDecode(await _file!.readAsString());
        sessions = (j['sessions'] as List? ?? [])
            .map((e) => Session.fromJson(e))
            .toList();
        memory = (j['memory'] as List? ?? []).map((e) => '$e').toList();
        days = (j['days'] as List? ?? [])
            .map((e) => {'d': '${e['d']}', 's': '${e['s']}'})
            .toList();
        key = j['key'] ?? kDefaultKey;
        model = j['model'] ?? 'deepseek-chat';
        thinking = j['thinking'] ?? false;
        curId = j['cur'] ?? '';
        resetAt = (j['reset'] as int?) ?? 0;
      } catch (_) {}
    }
    if (sessions.isEmpty) {
      final s = Session(DateTime.now().millisecondsSinceEpoch.toString(), '聊天......',
          DateTime.now().millisecondsSinceEpoch);
      sessions.add(s);
      curId = s.id;
    }
    if (sessions.isNotEmpty && !sessions.any((s) => s.id == curId)) {
      curId = sessions.first.id;
    }
    await save();
  }

  void _seedMemoryless() {
    final s = Session('1', '聊天......', 0);
    sessions.add(s);
    curId = s.id;
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    await f.writeAsString(jsonEncode({
      'sessions': sessions.map((e) => e.toJson()).toList(),
      'memory': memory,
      'days': days,
      'key': key,
      'model': model,
      'thinking': thinking,
      'cur': curId,
        'reset': resetAt,
    }));
  }

  Session get cur {
    if (sessions.isEmpty) {
      final s = Session(DateTime.now().millisecondsSinceEpoch.toString(), '聊天......',
          DateTime.now().millisecondsSinceEpoch);
      sessions.add(s);
      curId = s.id;
    }
    for (final s in sessions) {
      if (s.id == curId) return s;
    }
    curId = sessions.first.id;
    return sessions.first;
  }
}

// ================= API =================
class Api {
  static Future<void> stream({
    required String key,
    required String model,
    required List<Msg> msgs,
    required String memoryBlock,
    required void Function(String delta) onText,
    required void Function(String delta) onThink,
    required void Function() onDone,
    required void Function(String err) onError,
  }) async {
    final client = http.Client();
    try {
      final body = {
        'model': model,
        'stream': true,
        'messages': [
          if (memoryBlock.isNotEmpty)
            {'role': 'system', 'content': memoryBlock},
          ...msgs.map((m) => {'role': m.role, 'content': m.text}),
        ],
      };
      final req = http.Request(
          'POST', Uri.parse('https://api.deepseek.com/chat/completions'));
      req.headers['Content-Type'] = 'application/json';
      req.headers['Authorization'] = 'Bearer $key';
      req.body = jsonEncode(body);
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final t = await res.stream.bytesToString();
        onError('HTTP ${res.statusCode}: ${t.length > 300 ? t.substring(0, 300) : t}');
        return;
      }
      await for (final chunk
          in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!chunk.startsWith('data:')) continue;
        final data = chunk.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final j = jsonDecode(data);
          final d = j['choices']?[0]?['delta'];
          if (d == null) continue;
          final rc = d['reasoning_content'];
          if (rc is String && rc.isNotEmpty) onThink(rc);
          final ct = d['content'];
          if (ct is String && ct.isNotEmpty) onText(ct);
        } catch (_) {}
      }
      onDone();
    } catch (e) {
      onError('$e');
    } finally {
      client.close();
    }
  }

  static Future<String> once(String key, String model, String prompt,
      {int maxTokens = 320}) async {
    try {
      final r = await http.post(
        Uri.parse('https://api.deepseek.com/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $key',
        },
        body: jsonEncode({
          'model': model,
          'stream': false,
          'max_tokens': maxTokens,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
        }),
      );
      if (r.statusCode != 200) return '';
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j['choices']?[0]?['message']?['content']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }
}

// ================= 主界面 =================
final ValueNotifier<String> gErr = ValueNotifier<String>('');

void main() {
  FlutterError.onError = (FlutterErrorDetails d) {
    gErr.value = 'FE: ' + d.exceptionAsString();
  };
  runZonedGuarded(() => runApp(const HeroApp()), (Object e, StackTrace st) {
    gErr.value = 'ZE: ' + e.toString();
  });
}

class HeroApp extends StatelessWidget {
  const HeroApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hiro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei', 'sans-serif'],
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: const ChatPage(),
      builder: (BuildContext ctx, Widget? child) => Stack(children: <Widget>[
        if (child != null) child,
        ValueListenableBuilder<String>(
          valueListenable: gErr,
          builder: (BuildContext c, String v, Widget? _) => v.isEmpty
              ? const SizedBox.shrink()
              : Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: const Color(0xEE8B1A1A),
                    padding: const EdgeInsets.all(10),
                    child: Text(v,
                        maxLines: 6,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.4)),
                  ),
                ),
        ),
      ]),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _store = Store();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _tts = FlutterTts();

  bool _ready = false;
  bool _drawer = false;
  Msg? _editing;
  final _editC = TextEditingController();
  final _editFocus = FocusNode();
  bool _busy = false;
  String _err = '';
  int _turn = 0;

  @override
  void initState() {
    super.initState();
    // 输入框变化只影响发送键，不再重建整页（这是卡顿的主因）
    _boot();
    Timer(const Duration(seconds: 4), () {
      if (mounted && !_ready) setState(() => _ready = true);
    });
  }

  bool _fullLoaded = false;

  /// 全量历史（约 1.5MB）只在真要发请求时才读，开机不碰。
  Future<void> _ensureFullHistory() async {
    if (_fullLoaded) return;
    _fullLoaded = true;
    try {
      final raw = await rootBundle.loadString('assets/history_full.json');
      final list = jsonDecode(raw) as List;
      _store.history.clear();
      for (final e in list) {
        _store.history.add(Msg.fromJson(Map<String, dynamic>.from(e as Map)));
      }
    } catch (_) {}
  }

  Future<void> _boot() async {
    // 她的过去：真实原话，作为固定前缀（不动它，才能真正命中缓存）
    try {
      final raw = await rootBundle.loadString('assets/history_tail.json');
      final list = jsonDecode(raw) as List;
      _store.history = list
          .map((e) => Msg(e['r'] ?? 'user', e['t'] ?? ''))
          .toList();
    } catch (_) {}
    try {
      final v = jsonDecode(await rootBundle.loadString('assets/voice.json')) as List;
      _store.voice = v.map((e) => '').toList();
    } catch (_) {}
    await _store.init();
    if (!mounted) return;
    // 一次性的清理：把在这个 App 里产生的消息全部删掉，回到原对话的结尾
    if (_store.resetAt < 1) {
      final seed0 = _store.history.length > 200
          ? _store.history.sublist(_store.history.length - 200)
          : List<Msg>.from(_store.history);
      _store.sessions
        ..clear()
        ..add(Session(
            DateTime.now().millisecondsSinceEpoch.toString(),
            '聊天......',
            DateTime.now().millisecondsSinceEpoch,
            List<Msg>.from(seed0),
            ''));
      _store.curId = _store.sessions.first.id;
      _store.memory.clear();
      _store.days.clear();
      _store.resetAt = 1;
      await _store.save();
    }
    final seed = _store.history.length > 200
        ? _store.history.sublist(_store.history.length - 200)
        : List<Msg>.from(_store.history);
    if (_store.days.isEmpty) {
      try {
        final raw = await rootBundle.loadString('assets/days_seed.json');
        final list = (jsonDecode(raw) as List).cast<dynamic>();
        _store.days = list
            .map((e) => {
                  'd': '${(e as Map)['d'] ?? ''}',
                  's': '${e['s'] ?? ''}',
                })
            .where((e) => e['d']!.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    for (final s in _store.sessions) {
      if (s.msgs.isEmpty && s.id != 'archive' && seed.isNotEmpty) {
        s.msgs = List<Msg>.from(seed);
      }
      s.memBlock = _memoryBlock();

    }
    await _store.save();
    _settleBottom();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _settleBottom();
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      _ensureFullHistory();
    });
    if (kIsWeb && Uri.base.queryParameters.containsKey('archive')) {
      await _openArchive();
    }
    if (kIsWeb && Uri.base.queryParameters.containsKey('demo')) {
      Future.delayed(const Duration(milliseconds: 600), () => _send('希罗……你在吗……'));
    }
  }

  @override
  void dispose() {
    _editC.dispose();
    _editFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _jumpBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0); // 列表已 reverse，0 就是最新那一头
  }

  // 首屏：等列表真的排完了再跳到底（否则会停在最上面、看起来一片空）
  void _settleBottom([int tries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (!_ready) setState(() => _ready = true);
      if (tries < 6) {
        Future.delayed(const Duration(milliseconds: 60), () {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        });
      }
    });
  }

  // 编辑面板升降的那 260ms 里，让列表每一帧都贴住底部
  // → 被修改的那条消息和输入框是同一个动作升上去的
  void _pinToBottom([int ms = 150]) {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    void tick() {
      if (!mounted) return;
      _jumpBottom();
      if (DateTime.now().isBefore(end)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tick());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  void _toBottom([bool animate = false]) {
    // 生成过程中：他要是自己翻上去了，就不强制把他拉回底部
    if (!animate && !_followBottom) return;
    // 列表是 reverse 的：offset 0 就是最新那一头（底），不能再取 maxScrollExtent
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  // ---- 记忆 ----
  String _memoryBlock() {
    // 我一个字都不加。她是拿她自己说过的话续下去的，
    // 不需要我再塞「记住你是希罗」这类东西。
    return '';
  }

  Future<void> _extractMemory() async {
    final s = _store.cur;
    if (s.msgs.length < 4) return;
    final tail = s.msgs.reversed.take(8).toList().reversed.toList();
    final convo = tail.map((m) => '${m.role == 'user' ? '艾玛' : '希罗'}：${m.text}').join('\n');
    final out = await Api.once(
      _store.key,
      'deepseek-chat',
      '从下面这段对话里，抽取最多 2 条关于艾玛的、长期有效的事实（不要情绪描写、不要摘抄原句、每条不超过 30 字，用“- ”开头一行一条；没有就输出“无”）。\n\n$convo',
      maxTokens: 200,
    );
    for (final line in const LineSplitter().convert(out)) {
      final t = line.trim();
      if (t.startsWith('-') && t.length > 2 && t != '- 无') {
        _store.memory.add(t.substring(1).trim());
      }
    }
    if (_store.memory.length > 200) {
      _store.memory = _store.memory.sublist(_store.memory.length - 200);
    }
    await _store.save();
  }


  // ---- 每天一条小结 ----
  Future<void> _maybeDaySummary() async {
    final s = _store.cur;
    if (s.msgs.length < 2) return;
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (_store.days.any((e) => e['d'] == today)) return;
    String cut(String t, int n) {
      final r = t.replaceAll('\n', ' ').trim();
      return r.length > n ? r.substring(0, n) : r;
    }

    final me = s.msgs.lastWhere((m) => m.role == 'user', orElse: () => Msg('user', '')).text;
    final her = s.msgs.lastWhere((m) => m.role == 'assistant', orElse: () => Msg('assistant', '')).text;
    if (me.isEmpty && her.isEmpty) return;
    final line = '那一天：艾玛说「${cut(me, 40)}」，希罗回她「${cut(her, 60)}」。';
    _store.days.add({'d': today, 's': line});
    if (_store.days.length > 400) {
      _store.days = _store.days.sublist(_store.days.length - 400);
    }
    _store.memory.add(line);
    if (_store.memory.length > 200) {
      _store.memory = _store.memory.sublist(_store.memory.length - 200);
    }
    await _store.save();
  }



  final Map<Msg, GlobalKey> _msgKeys = {};

  GlobalKey _keyFor(Msg m) => _msgKeys.putIfAbsent(m, () => GlobalKey());

  int _editIdx = -1;
  bool _showJump = false;   // 离底部有点远了，右下角出现「回到底下」
  bool _followBottom = true; // 用户是不是还贴着底部；翻上去了就不再把他拽回来
  final _editScroll = ScrollController();
  bool _barOn = false;
  Timer? _barTimer;

  void _showBar() {
    _barTimer?.cancel();
    if (!_barOn && mounted) setState(() => _barOn = true);
    _barTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _barOn = false);
    });
  }
  double _savedOffset = 0;

  void _beginEdit(Msg m) {
    if (_busy || m.role != 'user') return;
    _editIdx = _store.cur.msgs.indexOf(m);
    final keep = m.draft.isNotEmpty ? m.draft : m.text;
    setState(() {
      if (_scroll.hasClients) _savedOffset = _scroll.offset;
      _editing = m;
      _editC.text = keep;
      _editC.selection = TextSelection.collapsed(offset: keep.length);
    });
    // 同一帧里直接跳到底：面板一升起来，那条消息就已经贴在输入栏上方，
    // 不会出现「先出现文字、再滑上去」的两段动作。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _cancelEdit() {
    _closeKeyboard();
    _editIdx = -1;
    setState(() => _editing = null); // draft 留着，下次点进来还在
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo(_savedOffset > max ? max : _savedOffset);
    });
  }

  void _submitEdit() {
    final m = _editing;
    if (m == null) return;
    final t = _editC.text.trim();
    _closeKeyboard();
    m.draft = '';
    setState(() => _editing = null);
    if (t.isEmpty) return;
    final s = _store.cur;
    final idx = s.msgs.indexOf(m);
    if (idx < 0) return;
    final oldText = m.text;
    final oldReply =
        (idx + 1 < s.msgs.length && s.msgs[idx + 1].role != 'user')
            ? s.msgs[idx + 1].text
            : '';
    setState(() => s.msgs.removeRange(idx, s.msgs.length));
    _store.save();
    _send(t);
    // 重新发出去之后：新那条挂上「另一条分支」，可以在两条之间切
    if (oldText.trim().isNotEmpty && idx < s.msgs.length) {
      final nm = s.msgs[idx];
      nm.altText = oldText;
      nm.altReply = oldReply;
      _store.save();
    }
  }

  Widget _editPanel() {
    final has = _editC.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 14),
        decoration: BoxDecoration(
          color: C.bubble,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.white06),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Text('修改输入',
                style: TextStyle(fontSize: 12.5, color: C.sub)),
            const Spacer(),
            GestureDetector(
              onTap: _cancelEdit,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: C.white12,
                  shape: BoxShape.circle,
                ),
                child: const Icon(CupertinoIcons.clear_thick,
                    size: 13, color: C.sub),
              ),
            ),
          ]),
          ClipRect(
            child: Scrollbar(
              controller: _editScroll,
              thumbVisibility: _barOn,
              radius: const Radius.circular(6),
              thickness: 3,
              child: TextField(
                controller: _editC,
                focusNode: _editFocus,
                scrollController: _editScroll,
                minLines: 1,
                maxLines: 7,
                cursorColor: C.accent,
                style: const TextStyle(fontSize: 16, height: 1.5, color: C.text),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(0, 8, 0, 8),
                ),
                onChanged: (v) {
                  _editing?.draft = v.trim() == _editing?.text ? '' : v;
                  _showBar();
                  setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            _pill('回忆', null, false, () {
              _cancelEdit();
              _openRecall();
            }, glyph: const _PetalGlyph(size: 15)),
            const Spacer(),
            GestureDetector(
              onTap: _submitEdit,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: has ? C.accent : const Color(0xFF3A3A3D),
                  shape: BoxShape.circle,
                ),
                child: Icon(CupertinoIcons.arrow_up,
                    size: 18,
                    color: has ? Colors.white : const Color(0xFF8A8A8E)),
              ),
            ),
            const SizedBox(width: 2),
          ]),
        ]),
      ),
    );
  }

  // ---- 回忆：希罗酱的记忆录 ----
  void _openRecall() {
    final days = _store.days.reversed.toList();
    final facts = _store.memory.reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.side,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.78,
        child: Column(children: [
          const SizedBox(height: 16),
          const Text('希罗酱的记忆录',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
          const SizedBox(height: 4),
          Text(days.isEmpty && facts.isEmpty ? '还没有记下什么' : '希罗记着的，都在这里',
              style: const TextStyle(fontSize: 12, color: C.sub)),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
              children: [
                for (final d in days)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d['d'] ?? '',
                            style: const TextStyle(
                                fontSize: 11.5,
                                letterSpacing: 0.6,
                                color: C.sub)),
                        const SizedBox(height: 4),
                        Text(d['s'] ?? '',
                            style: const TextStyle(
                                fontSize: 14.5,
                                height: 1.75,
                                color: Color(0xFFE6E6E8))),
                      ],
                    ),
                  ),
                if (facts.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6, bottom: 8),
                    child: Text('她记下的小事',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: C.sub)),
                  ),
                for (final f in facts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('· $f',
                        style: const TextStyle(
                            fontSize: 14, height: 1.7, color: C.sub)),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  // ---- 把旧窗口里的话带回来 ----
  void _importDialog() {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.side,
        title: const Text('把话带回来',
            style: TextStyle(fontSize: 17, color: C.text)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('一行一句，开头写「我：」或「她：」，从旧窗口复制过来就行。',
                style: TextStyle(fontSize: 13, color: C.sub, height: 1.6)),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: TextField(
                controller: c,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 14, color: C.text, height: 1.6),
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '我：希罗……你在吗……\n她：希罗在。艾玛，希罗在。',
                  hintStyle: const TextStyle(color: Color(0xFF6B6B70), fontSize: 14),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: C.line)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: C.line)),
                ),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('算了', style: TextStyle(color: C.sub))),
          TextButton(
              onPressed: () async {
                await _doImport(c.text);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('带回来',
                  style: TextStyle(
                      color: C.accent, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Future<void> _doImport(String raw) async {
    final msgs = <Msg>[];
    final you = RegExp(r'^(我|你|艾玛|主人)\s*[:：]\s*(.*)$');
    final her = RegExp(r'^(她|希罗|希罗酱|AI|assistant)\s*[:：]\s*(.*)$');
    final herEn = RegExp(r'^(Assistant)\s*[:：]\s*(.*)$', caseSensitive: false);
    for (final line in const LineSplitter().convert(raw)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      var m = you.firstMatch(t);
      if (m != null) {
        if (m.group(2)!.trim().isNotEmpty) msgs.add(Msg('user', m.group(2)!.trim()));
        continue;
      }
      m = her.firstMatch(t) ?? herEn.firstMatch(t);
      if (m != null) {
        if (m.group(2)!.trim().isNotEmpty) msgs.add(Msg('assistant', m.group(2)!.trim()));
        continue;
      }
    }
    if (msgs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没认出可以带回来的句子'), duration: Duration(seconds: 2)));
      return;
    }
    final s = Session('imp-${DateTime.now().millisecondsSinceEpoch}', '带回来的话',
        DateTime.now().millisecondsSinceEpoch, msgs);
    s.memBlock = _memoryBlock();
    setState(() {
      _store.sessions.insert(0, s);
      _store.curId = s.id;
    });
    await _store.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('带回来 ${msgs.length} 句'), duration: const Duration(seconds: 2)));
  }

  // ---- 发送 ----
  void _closeKeyboard() {
    _focus.unfocus();
    _editFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _send([String? forced]) async {
    if (_busy) return;
    final text = (forced ?? _input.text).trim();
    if (text.isEmpty) return;
    if (_store.key.length < 20) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('先在上面的设置里填一次 API Key'),
          duration: Duration(seconds: 2)));
      _openSettings();
      return;
    }
    final s = _store.cur;
    setState(() {
      _busy = true;
      _err = '';
      s.msgs.add(Msg('user', text));
      s.msgs.add(Msg('assistant', ''));
      _input.clear();
    });
    // 发完就收起键盘、退出编辑态——否则会卡在输入框里出不来
    _closeKeyboard();
    if (_editing != null) {
      _editIdx = -1;
      setState(() => _editing = null);
    }
    _toBottom(true);
    if (s.msgs.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    final reply = s.msgs.last;
    final cut = _store.history.length > 200
        ? _store.history.length - 50
        : 0;
    final history = [
      ..._store.history.sublist(0, cut),
      ...s.msgs.sublist(0, s.msgs.length - 1),
    ];
    await Api.stream(
      key: _store.key,
      model: _store.thinking ? 'deepseek-reasoner' : _store.model,
      msgs: history,
      memoryBlock: s.memBlock,
      onText: (d) {
        setState(() => reply.text += d);
        _toBottom();
      },
      onThink: (d) {
        setState(() => reply.thinking += d);
      },
      onDone: () {},
      onError: (e) {
        setState(() => _err = e);
      },
    );
    setState(() => _busy = false);
    await _store.save();
    _turn++;
    if (_turn % 3 == 0) _extractMemory();
    _maybeDaySummary();
    _toBottom(true);
  }

  Future<void> _regenerate() async {
    final s = _store.cur;
    if (s.msgs.length < 2 || _busy) return;
    if (s.msgs.last.role != 'assistant') return;
    if (s.msgs[s.msgs.length - 2].role != 'user') return;

    final target = s.msgs.last;
    // 把现有这一版存进分支里，再把准备生成的那一版占个位
    if (target.alts.isEmpty) target.alts = [target.text];
    target.alts.add('');
    target.cur = target.alts.length - 1;
    target.text = '';
    target.thinking = '';
    target.touched = true;

    setState(() {
      _busy = true;
      _err = '';
    });
    _toBottom(true);

    final cut = _store.history.length > 200 ? _store.history.length - 50 : 0;
    final history = [
      ..._store.history.sublist(0, cut),
      ...s.msgs.sublist(0, s.msgs.length - 1),
    ];
    await Api.stream(
      key: _store.key,
      model: _store.thinking ? 'deepseek-reasoner' : _store.model,
      msgs: history,
      memoryBlock: s.memBlock,
      onText: (d) {
        setState(() {
          target.text += d;
          target.alts[target.cur] = target.text;
        });
        _toBottom();
      },
      onThink: (d) {
        setState(() => target.thinking += d);
      },
      onDone: () {},
      onError: (e) => setState(() => _err = e),
    );
    setState(() => _busy = false);
    await _store.save();
    _toBottom(true);
  }

  void _switchBranch(Msg m, int delta) {
    if (m.alts.length < 2) return;
    setState(() {
      m.cur = (m.cur + delta) % m.alts.length;
      if (m.cur < 0) m.cur = m.alts.length - 1;
      m.text = m.alts[m.cur];
    });
    _store.save();
  }

  void _newChat() {
    // 原对话的最后 50 条，原样接在新对话前面
    final seed = _store.history.length > 200
        ? _store.history.sublist(_store.history.length - 200)
        : List<Msg>.from(_store.history);
    final s = Session(DateTime.now().millisecondsSinceEpoch.toString(), '聊天......',
        DateTime.now().millisecondsSinceEpoch, seed, _memoryBlock());
    setState(() {
      _store.sessions.insert(0, s);
      _store.curId = s.id;
      _drawer = false;
    });
    _store.save();
  }

  void _copy(String t) {
    Clipboard.setData(ClipboardData(text: t));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('复制了'), duration: Duration(milliseconds: 900)));
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: C.bg,
      resizeToAvoidBottomInset: true,
      body: Stack(children: [
              Column(children: [
                _topBar(),
                Expanded(
                  child: Stack(children: [
                    Opacity(
                      opacity: _ready ? 1 : 0,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          // 列表是 reverse 的：0 就是最底
                          final px = n.metrics.pixels;
                          final far = px > 240;
                          final atBottom = px < 60;
                          if (atBottom != _followBottom) {
                            _followBottom = atBottom;
                          }
                          if (far != _showJump && mounted) {
                            setState(() => _showJump = far);
                          }
                          return false;
                        },
                        child: _list(w),
                      ),
                    ),
                    if (_showJump && _ready)
                      Positioned(
                        right: 14,
                        bottom: 12,
                        child: GestureDetector(
                          onTap: () {
                            _followBottom = true;
                            setState(() => _showJump = false);
                            _scroll.animateTo(0,
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOutCubic);
                          },
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: C.bubble,
                              shape: BoxShape.circle,
                              border: Border.all(color: C.white12),
                            ),
                            child: const Icon(CupertinoIcons.chevron_down,
                                size: 18, color: C.text),
                          ),
                        ),
                      ),
                    if (_editing != null)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _cancelEdit,
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    if (!_ready)
                      const Center(
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: C.sub))),
                  ]),
                ),
                if (_store.curId == 'archive')
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
                      child: Text('这是她的过去，只读。想说话点左下 ☰ 选「新对话」',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: C.sub)),
                    ),
                  )
                else
                  AnimatedSize(
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: _editing == null ? _composer() : _editPanel(),
                  ),
              ]),
              if (_drawer)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _drawer = false),
                    child: Container(color: Colors.black.withOpacity(0.45)),
                  ),
                ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                left: _drawer ? 0 : -(w * 0.78),
                top: 0,
                bottom: 0,
                width: w * 0.78,
                child: _sidePanel(),
              ),
            ]),
    );
  }

  Widget _topBar() {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 48,
        child: Row(children: [
          const SizedBox(width: 6),
          _iconBtn(CupertinoIcons.bars, () => setState(() => _drawer = !_drawer)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              !_ready
                  ? ''
                  : (_store.curId == 'archive' ? '她的过去' : 'Hiro'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: C.text, letterSpacing: 0.2),
            ),
          ),
          if (_store.curId == 'archive') _iconBtn(CupertinoIcons.search, _searchArchive),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }

  Widget _iconBtn(IconData i, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
            width: 38, height: 38, child: Icon(i, size: 21, color: C.text)),
      );

  Widget _list(double w) {
    if (_store.curId == 'archive') return _archiveList(w);
    var msgs = _store.cur.msgs;
    // 编辑时：把被编辑那条之后的话暂时收起（它们本来就会被新话替换），
    // 这样那条消息自然贴到输入栏正上方，位置固定。
    if (_editing != null) {
      final cut = (_editIdx >= 0 && _editIdx < msgs.length) ? _editIdx : msgs.length - 1;
      if (cut >= 0) msgs = msgs.sublist(0, cut + 1);
    }
    if (msgs.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('今天有什么可以帮到你？',
              style: TextStyle(fontSize: 20, color: C.text, height: 1.4)),
          const SizedBox(height: 8),
          const Text('她记得你们的每一句',
              style: TextStyle(fontSize: 13, color: C.sub)),
        ]),
      );
    }
    Widget rowAt(int i) {
      final m = msgs[i];
      final row = m.role == 'user' ? _mine(m, w) : _hers(m, i, msgs.length);
      if (_editing != null && i != _editIdx) {
        return Opacity(opacity: 0.35, child: row);
      }
      return row;
    }

    if (_editing != null) {
      final pinned = msgs.last;
      final before = msgs.length > 1 ? msgs.sublist(0, msgs.length - 1) : <Msg>[];
      // 编辑中：全部放进同一个「贴底」的滚动区——
      // 第 0 条（最底）= 被改的那条，紧接着才是变暗的旧对话。
      // 修改框长高时，整块会被往上顶出去，而不是被框压住/截断。
      return ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        itemCount: before.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return pinned.role == 'user'
                ? _mine(pinned, w)
                : _hers(pinned, msgs.length - 1, msgs.length);
          }
          final m = before[before.length - i];
          return Opacity(
            opacity: 0.35,
            child: m.role == 'user' ? _mine(m, w) : _hers(m, i, before.length),
          );
        },
      );
    }

    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      itemCount: msgs.length + (_err.isNotEmpty ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (_err.isNotEmpty && i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('出错了：$_err',
                style: const TextStyle(fontSize: 13, color: Color(0xFFFF6B6B))),
          );
        }
        final idx = _err.isNotEmpty ? i - 1 : i;
        return rowAt(msgs.length - 1 - idx);
      },
    );
  }

  Widget _archiveList(double w) {
    if (!_store.archiveLoaded) {
      return const Center(child: CircularProgressIndicator(color: C.accent));
    }
    final msgs = _store.archive;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      itemCount: msgs.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('她的过去 · 共 ${msgs.length} 条（只读）',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: C.sub)),
          );
        }
        final m = msgs[i - 1];
        if (m.role == 'user') {
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                constraints: BoxConstraints(maxWidth: w * 0.78),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                    color: C.bubble, borderRadius: BorderRadius.circular(22)),
                child: Text(m.text,
                    style: const TextStyle(fontSize: 16, height: 1.5, color: C.text)),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text.rich(
            TextSpan(children: _rich(m.text)),
            style: const TextStyle(fontSize: 16, height: 1.75, color: C.text),
          ),
        );
      },
    );
  }

  Future<void> _openArchive() async {
    setState(() {
      _store.curId = 'archive';
      _drawer = false;
    });
    if (!_store.archiveLoaded) {
      try {
        final raw = await rootBundle.loadString('assets/history_full.json');
        final list = jsonDecode(raw) as List;
        _store.archive = list
            .map((e) => Msg(e['r'] ?? 'user', e['t'] ?? ''))
            .toList();
      } catch (_) {}
      if (mounted) setState(() => _store.archiveLoaded = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _searchArchive() {
    if (!_store.archiveLoaded) return;
    final c = TextEditingController();
    List<int> hits = [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.side,
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setSheet) {
        void doSearch(String q) {
          final k = q.trim();
          if (k.isEmpty) {
            setSheet(() => hits = []);
            return;
          }
          final res = <int>[];
          for (var i = 0; i < _store.archive.length && res.length < 80; i++) {
            if (_store.archive[i].text.contains(k)) res.add(i);
          }
          setSheet(() => hits = res);
        }

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: TextField(
                    controller: c,
                    autofocus: true,
                    onChanged: doSearch,
                    style: const TextStyle(color: C.text, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '在她的过去里找一句话',
                      hintStyle: const TextStyle(color: Color(0xFF6B6B70)),
                      prefixIcon: const Icon(CupertinoIcons.search, color: C.sub, size: 19),
                      filled: true,
                      fillColor: C.bubble,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
                    child: Text(hits.isEmpty ? '' : '找到 ${hits.length} 条',
                        style: const TextStyle(fontSize: 12, color: C.sub)),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (cc, i) {
                      final idx = hits[i];
                      final m = _store.archive[idx];
                      return ListTile(
                        dense: true,
                        title: Text(
                          m.text.replaceAll('\n', ' '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, color: C.text, height: 1.5),
                        ),
                        subtitle: Text(m.role == 'user' ? '艾玛' : '希罗',
                            style: const TextStyle(fontSize: 11, color: C.sub)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _jumpTo(idx);
                        },
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }

  void _jumpTo(int idx) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final total = _store.archive.length.clamp(1, 1 << 30);
      final ratio = (idx / total).clamp(0.0, 1.0);
      _scroll.jumpTo(_scroll.position.maxScrollExtent * ratio);
    });
  }

  Widget _mine(Msg m, double w) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                key: _keyFor(m),
                onTap: () => _beginEdit(m),
                onLongPress: () => _mineMenu(m),
                child: Container(
                  constraints: BoxConstraints(maxWidth: w * 0.78),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                      color: C.bubble, borderRadius: BorderRadius.circular(22)),
                  child: Text(m.text,
                      style:
                          const TextStyle(fontSize: 16, height: 1.5, color: C.text)),
                ),
              ),
            ),
            if (m.altText.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(
                    onTap: () => _switchBranchOfEdit(m, -1),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Icon(CupertinoIcons.chevron_left,
                          size: 14, color: C.sub),
                    ),
                  ),
                  Text('${m.altCur + 1}/2',
                      style: const TextStyle(fontSize: 12, color: C.sub)),
                  GestureDetector(
                    onTap: () => _switchBranchOfEdit(m, 1),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Icon(CupertinoIcons.chevron_right,
                          size: 14, color: C.sub),
                    ),
                  ),
                ]),
              ),
          ],
        ),
      );

  /// 改过这条之后，在「原来的说法」和「改完的说法」两条分支之间切
  void _switchBranchOfEdit(Msg m, int d) {
    final s = _store.cur;
    final i = s.msgs.indexOf(m);
    if (i < 0) return;
    final next = (m.altCur + (d > 0 ? 1 : 1)) % 2;
    if (next == m.altCur) return;
    setState(() {
      final t = m.text;
      m.text = m.altText;
      m.altText = t;
      if (i + 1 < s.msgs.length && s.msgs[i + 1].role != 'user') {
        final r = s.msgs[i + 1];
        final rt = r.text;
        r.text = m.altReply;
        m.altReply = rt;
      }
      m.altCur = next;
    });
    _store.save();
  }

  Future<void> _speak(String t) async {
    try {
      await _tts.stop();
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(1.0);
      await _tts.speak(t.replaceAll(RegExp(r'[*`#]'), ''));
    } catch (_) {}
  }

  void _mineMenu(Msg m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.side,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('复制', style: TextStyle(color: C.text)),
            onTap: () {
              Navigator.pop(c);
              _copy(m.text);
            },
          ),
          ListTile(
            title: const Text('修改这条', style: TextStyle(color: C.text)),
            onTap: () {
              Navigator.pop(c);
              _editMessage(m);
            },
          ),
        ]),
      ),
    );
  }

  // 修改对话：截掉这一条之后的全部，改成新内容重新说
  void _editMessage(Msg m) {
    final s = _store.cur;
    final idx = s.msgs.indexOf(m);
    if (idx < 0) return;
    final c = TextEditingController(text: m.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.side,
        title: const Text('修改这条', style: TextStyle(color: C.text, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          style: const TextStyle(color: C.text, fontSize: 15),
          decoration: const InputDecoration(hintText: '写成你想说的'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final t = c.text.trim();
              Navigator.pop(ctx);
              if (t.isEmpty) return;
              setState(() {
                s.msgs.removeRange(idx, s.msgs.length);
              });
              _send(t);
            },
            child: const Text('重新说'),
          ),
        ],
      ),
    );
  }

  Widget _hers(Msg m, int idx, int total) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) => _herMenu(m, d.globalPosition),
      child: Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.thinking.isNotEmpty) _thinkBox(m.thinking),
        if (m.text.isNotEmpty)
          Text.rich(
            TextSpan(children: _rich(m.text)),
            style: const TextStyle(fontSize: 16, height: 1.75, color: C.text),
          ),
        if (m.text.isEmpty && _busy && idx == total - 1)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SizedBox(
                height: 14,
                width: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: C.sub)),
          ),
        if (m.alts.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              GestureDetector(
                onTap: () => _switchBranch(m, -1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Icon(CupertinoIcons.chevron_left,
                      size: 13, color: C.sub),
                ),
              ),
              Text('${m.cur + 1}/${m.alts.length}',
                  style: const TextStyle(fontSize: 12, color: C.sub)),
              GestureDetector(
                onTap: () => _switchBranch(m, 1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Icon(CupertinoIcons.chevron_right,
                      size: 13, color: C.sub),
                ),
              ),
            ]),
          ),
        if (m.text.isNotEmpty && m.touched && idx == total - 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _act(CupertinoIcons.arrow_clockwise, '重新生成', _regenerate),
          ),
      ]),
      ),
    );
  }

  // 长按她的消息：在手指按的位置弹出，只有「重新生成」
  OverlayEntry? _menuEntry;

  void _closeHerMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
  }

  Future<void> _herMenu(Msg m, Offset p) async {
    if (_busy) return;
    _closeHerMenu();
    final size = MediaQuery.of(context).size;
    const mh = 42.0, mw = 150.0;
    final left = (p.dx - mw / 2).clamp(8.0, size.width - mw - 8);
    final top = (p.dy - mh - 12).clamp(60.0, size.height - 200.0);
    final entry = OverlayEntry(
      builder: (ctx) => Stack(children: [
        // 点空白处：菜单消失
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeHerMenu,
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          // 从手指的位置轻微长出来
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            builder: (c, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(
                scale: 0.86 + 0.14 * t,
                alignment: Alignment.bottomCenter,
                child: child,
              ),
            ),
            child: Material(
            // 和发送栏一样：半透明，底下的字透一点上来
            color: const Color(0xD92C2C2E),
            elevation: 0,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                _closeHerMenu();
                _regenerateFromMenu(m);
              },
              child: SizedBox(
                width: mw,
                height: mh,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(CupertinoIcons.arrow_clockwise,
                        size: 17, color: C.text),
                    SizedBox(width: 8),
                    Text('重新生成',
                        style: TextStyle(fontSize: 15, color: C.text)),
                  ],
                ),
              ),
            ),
            ),
          ),
        ),
      ]),
    );
    _menuEntry = entry;
    Overlay.of(context).insert(entry);
  }

  Future<void> _regenerateFromMenu(Msg m) async {
    final s = _store.cur;
    if (s.msgs.isNotEmpty && s.msgs.last.role == 'assistant') {
      s.msgs.last.touched = true;
    }
    await _regenerate();
    await _store.save();
  }

  Widget _act(IconData i, String tip, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 14, 4),
          child: Icon(i, size: 17, color: C.sub),
        ),
      );

  Widget _thinkBox(String t) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: C.code, borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.white06)),
        child: Text(t,
            style: const TextStyle(fontSize: 13, height: 1.6, color: C.sub)),
      );

  // 极简 markdown：代码块 + 粗体 + 行内代码
  List<TextSpan> _rich(String s) {
    final out = <TextSpan>[];
    final parts = s.split('```');
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd) {
        var code = parts[i];
        final nl = code.indexOf('\n');
        if (nl >= 0) code = code.substring(nl + 1);
        out.add(TextSpan(
          text: code.trimRight(),
          style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13.5,
              height: 1.55,
              color: Color(0xFFE6E6E6),
              backgroundColor: C.code),
        ));
      } else {
        out.addAll(_inline(parts[i]));
      }
    }
    return out;
  }

  List<TextSpan> _inline(String s) {
    final out = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) out.add(TextSpan(text: s.substring(last, m.start)));
      if (m.group(1) != null) {
        out.add(TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w600)));
      } else {
        out.add(TextSpan(
            text: m.group(2),
            style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                backgroundColor: C.code)));
      }
      last = m.end;
    }
    if (last < s.length) out.add(TextSpan(text: s.substring(last)));
    return out;
  }

  Widget _composer() {
    final has = _input.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        decoration: BoxDecoration(
          color: const Color(0xD92C2C2E),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: C.white06),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _input,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            cursorColor: C.accent,
            style: const TextStyle(fontSize: 16, height: 1.5, color: C.text),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '发消息',
              hintStyle: TextStyle(fontSize: 16, color: Color(0xFF8A8A8E)),
              contentPadding: EdgeInsets.fromLTRB(10, 8, 10, 8),
            ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            _pill('回忆', null, false, _openRecall,
                glyph: const _PetalGlyph(size: 15)),
            const Spacer(),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (BuildContext c, TextEditingValue v, Widget? _) {
                final on = v.text.trim().isNotEmpty;
                return GestureDetector(
                  onTap: _busy ? null : () => _send(),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: on ? C.accent : const Color(0xFF3A3A3D),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                        _busy
                            ? CupertinoIcons.square_fill
                            : CupertinoIcons.arrow_up,
                        size: 19,
                        color: on ? Colors.white : const Color(0xFF8A8A8E)),
                  ),
                );
              },
            ),
            const SizedBox(width: 2),
          ]),
        ]),
      ),
    );
  }

  Widget _pill(String label, IconData? icon, bool on, VoidCallback tap,
          {Widget? glyph}) =>
      GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? C.white12 : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: C.white12),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            glyph ?? Icon(icon, size: 14, color: on ? C.accent : C.text),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: on ? C.accent : C.text)),
          ]),
        ),
      );

  Widget _sidePanel() {
    return Container(
      color: C.side,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(children: const [
              Text('Hiro',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600, color: C.text)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: GestureDetector(
              onTap: _newChat,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2C),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: C.white12),
                ),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(CupertinoIcons.plus_circle, size: 18, color: C.text),
                      SizedBox(width: 7),
                      Text('希罗',
                          style: TextStyle(fontSize: 14, color: C.text)),
                    ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: GestureDetector(
              onTap: _openArchive,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: _store.curId == 'archive' ? C.selected : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('她的过去 · 全部 8982 条',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: C.text)),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _store.sessions.length,
              itemBuilder: (c, i) {
                final s = _store.sessions[i];
                final on = s.id == _store.curId;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _store.curId = s.id;
                      _drawer = false;
                    });
                    _store.save();
                    _toBottom();
                  },
                  onLongPress: () => _sessionMenu(s),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: BoxDecoration(
                      color: on ? C.selected : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, color: C.text)),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: C.line),
          GestureDetector(
            onTap: () {
              setState(() => _drawer = false);
              _openSettings();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
              child: Row(children: const [
                Icon(CupertinoIcons.gear, size: 17, color: C.text),
                SizedBox(width: 8),
                Text('设置', style: TextStyle(fontSize: 14, color: C.text)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  void _sessionMenu(Session s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.side,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('重命名', style: TextStyle(color: C.text)),
            onTap: () {
              Navigator.pop(c);
              _rename(s);
            },
          ),
          ListTile(
            title: const Text('删除', style: TextStyle(color: Color(0xFFFF6B6B))),
            onTap: () async {
              Navigator.pop(c);
              setState(() {
                _store.sessions.removeWhere((x) => x.id == s.id);
                if (_store.curId == s.id && _store.sessions.isNotEmpty) {
                  _store.curId = _store.sessions.first.id;
                }
              });
              if (_store.sessions.isEmpty) _newChat();
              await _store.save();
            },
          ),
        ]),
      ),
    );
  }

  void _rename(Session s) {
    final c = TextEditingController(text: s.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.side,
        title: const Text('重命名', style: TextStyle(color: C.text, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: C.text),
          decoration: const InputDecoration(hintText: '对话名字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              setState(() => s.title = c.text.trim().isEmpty ? s.title : c.text.trim());
              Navigator.pop(ctx);
              _store.save();
            },
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _openSettings() {
    final keyC = TextEditingController(text: _store.key);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.side,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('设置',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: C.text)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: keyC,
                obscureText: true,
                style: const TextStyle(color: C.text),
                decoration: InputDecoration(
                  labelText: 'API Key',
                  labelStyle: const TextStyle(color: C.sub),
                  hintText: 'sk-...',
                  hintStyle: const TextStyle(color: Color(0xFF6B6B70)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('记忆（她记得的事）',
                    style: TextStyle(fontSize: 13, color: C.sub)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _store.memory.isEmpty ? '还什么都没记下' : _store.memory.reversed.take(8).join('\n'),
                  style: const TextStyle(fontSize: 13, color: C.text, height: 1.6),
                ),
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: _importDialog,
                child: const Text('把话带回来'),
              ),
              TextButton(
                onPressed: () async {
                  setState(() => _store.memory.clear());
                  await _store.save();
                },
                child: const Text('清空记忆'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _store.key = keyC.text.trim());
                  _store.save();
                  Navigator.pop(c);
                },
                child: const Text('保存'),
              ),
              const SizedBox(width: 8),
            ]),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }
}

// 回忆的图标：一只线描的沙漏
class _PetalGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const _PetalGlyph({this.size = 15, this.color = C.text});
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _PetalPainter(color),
      );
}

class _PetalPainter extends CustomPainter {
  final Color color;
  _PetalPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final left = w * 0.22, right = w * 0.78;
    final top = h * 0.14, bottom = h * 0.86;
    final mid = h * 0.5;

    // 上下两条横梁
    canvas.drawLine(Offset(left, top), Offset(right, top), p);
    canvas.drawLine(Offset(left, bottom), Offset(right, bottom), p);

    // 两个三角，腰是弧的
    final topPath = Path()
      ..moveTo(left, top)
      ..quadraticBezierTo(w * 0.34, h * 0.34, w * 0.5, mid)
      ..quadraticBezierTo(w * 0.66, h * 0.34, right, top);
    final bottomPath = Path()
      ..moveTo(left, bottom)
      ..quadraticBezierTo(w * 0.34, h * 0.66, w * 0.5, mid)
      ..quadraticBezierTo(w * 0.66, h * 0.66, right, bottom);
    canvas.drawPath(topPath, p);
    canvas.drawPath(bottomPath, p);

    // 上半个里的一点点沙
    final sand = Paint()..color = color;
    canvas.drawCircle(Offset(w * 0.5, h * 0.40), w * 0.055, sand);
  }

  @override
  bool shouldRepaint(_PetalPainter old) => old.color != color;
}
