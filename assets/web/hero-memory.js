/* hero 记忆层：只做事实记忆，不改说话方式。
 * 做法：
 *  1) 拦截发往 /anthropic/v1/messages 的请求，把"记忆"拼进 system 的最前面；
 *  2) 每累积若干轮，悄悄发一次很小的抽取请求，把事实存进 localStorage；
 *  3) token 有上限：记忆总量封顶，注入封顶。
 */
(function () {
  'use strict';

  var LS = 'hero.memory.v1';
  var LS_TURN = 'hero.turncount.v1';
  var MAX_ITEMS = 40;        // 最多存 40 条
  var INJECT_ITEMS = 12;     // 每次最多注入 12 条
  var INJECT_CHARS = 900;    // 注入总字数上限
  var EXTRACT_EVERY = 6;     // 每 6 轮抽取一次
  var EXTRACT_MAX_TOK = 220; // 抽取请求的输出上限

  function load() {
    try { var a = JSON.parse(localStorage.getItem(LS) || '[]'); return Array.isArray(a) ? a : []; }
    catch (e) { return []; }
  }
  function save(arr) {
    while (arr.length > MAX_ITEMS) arr.shift();
    try { localStorage.setItem(LS, JSON.stringify(arr)); } catch (e) {}
  }

  // ---- 关键词命中：用两字片段做粗匹配，够用且便宜 ----
  function grams(s) {
    var out = {}, i;
    for (i = 0; i + 1 < s.length; i++) {
      var g = s.substr(i, 2);
      if (/[\u4e00-\u9fa5a-zA-Z0-9]/.test(g)) out[g] = 1;
    }
    return out;
  }
  function pick(latestUserText) {
    var mem = load();
    if (!mem.length) return [];
    var g = grams(latestUserText || '');
    var scored = mem.map(function (m, idx) {
      var hit = 0, mg = grams(m.text || '');
      for (var k in mg) if (g[k]) hit++;
      return { m: m, idx: idx, score: hit * 10 + idx }; // 旧的略降权
    });
    scored.sort(function (a, b) { return b.score - a.score; });
    var chosen = scored.slice(0, INJECT_ITEMS).map(function (x) { return x.m; });
    // 按时间回排，读起来顺序自然
    chosen.sort(function (a, b) { return (a.t || 0) - (b.t || 0); });
    var out = [], total = 0;
    for (var i = 0; i < chosen.length; i++) {
      var line = '· ' + chosen[i].text;
      if (total + line.length > INJECT_CHARS) break;
      total += line.length;
      out.push(line);
    }
    return out;
  }

  function memoryBlock(latestUserText) {
    var lines = pick(latestUserText);
    if (!lines.length) return '';
    return (
      '以下是此前聊过、值得记住的事实（只当作背景事实使用，不要逐条复述，也不要用它改变说话方式）：\n' +
      lines.join('\n') + '\n\n'
    );
  }

  // ---- 抽取：把最近一段对话压成 1~3 条事实 ----
  var busy = false;
  function lastUserText() {
    var els = document.querySelectorAll('[data-hero-user]');
    if (els.length) return els[els.length - 1].innerText || '';
    return '';
  }

  function extract(apiKey, model, baseUrl, convoText) {
    if (busy || !apiKey || !convoText) return;
    busy = true;
    var prompt =
      '从下面这段对话里，提取 1~3 条"以后还用得上"的事实，每条一行，以「- 」开头，不超过 30 字。\n' +
      '只写事实（人、事、约定、偏好、称呼、正在做的事），不要写情绪评价，不要复述原句，不要写"用户说"。\n' +
      '如果这段没有值得长期记住的，就只输出：无\n\n对话：\n' + convoText.slice(-2500);
    fetch(baseUrl + '/anthropic/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'x-hero-memory': '1'
      },
      body: JSON.stringify({
        model: model,
        system: '你是一个只做信息抽取的工具，不做对话。',
        messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] }],
        thinking: { type: 'disabled' },
        tools: [],
        safety_check: { level: 'high' },
        max_tokens: EXTRACT_MAX_TOK,
        stream: false
      })
    })
      .then(function (r) { return r.text(); })
      .then(function (txt) {
        var facts = [];
        // SSE 或 JSON 都可能，粗暴抓所有 text
        var re = /"text"\s*:\s*"((?:[^"\\]|\\.)*)"/g, m;
        while ((m = re.exec(txt))) {
          try { facts.push(JSON.parse('"' + m[1] + '"')); } catch (e) {}
        }
        var joined = facts.join('\n');
        var arr = load();
        joined.split('\n').forEach(function (line) {
          line = line.replace(/^[\s\-·•*]+/, '').trim();
          if (!line || line === '无' || line.length < 2 || line.length > 60) return;
          arr.push({ t: Date.now(), text: line });
        });
        save(arr);
      })
      .catch(function () {})
      .then(function () { busy = false; });
  }

  // ---- 拦截 fetch ----
  var origFetch = window.fetch;
  if (!origFetch) return;
  window.fetch = function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('/anthropic/v1/messages') >= 0 && init && init.method === 'POST' && init.body) {
        var isExtract = init.headers && (init.headers['x-hero-memory'] || init.headers['X-Hero-Memory']);
        if (!isExtract) {
          var body = JSON.parse(init.body);
          if (!body.title) {
            // 取最后一条用户消息做检索
            var lastUser = '';
            if (Array.isArray(body.messages)) {
              for (var i = body.messages.length - 1; i >= 0; i--) {
                var mm = body.messages[i];
                if (mm && mm.role === 'user') {
                  lastUser = typeof mm.content === 'string' ? mm.content
                    : (mm.content || []).map(function (c) { return c && c.text ? c.text : ''; }).join(' ');
                  break;
                }
              }
            }
            var blk = memoryBlock(lastUser);
            if (blk) body.system = blk + (body.system || '');

            // 攒够轮次就抽取一次
            var n = parseInt(localStorage.getItem(LS_TURN) || '0', 10) + 1;
            localStorage.setItem(LS_TURN, String(n));
            if (n % EXTRACT_EVERY === 0) {
              var key = (init.headers && (init.headers['x-api-key'] || init.headers['X-Api-Key'])) || '';
              var conv = '';
              (body.messages || []).slice(-8).forEach(function (m2) {
                var c = typeof m2.content === 'string' ? m2.content
                  : (m2.content || []).map(function (x) { return x && x.text ? x.text : ''; }).join(' ');
                if (c) conv += (m2.role === 'user' ? '我：' : '她：') + c + '\n';
              });
              extract(key, body.model, url.replace(/\/anthropic\/v1\/messages.*$/, ''), conv);
            }
            init = Object.assign({}, init, { body: JSON.stringify(body) });
          }
        }
      }
    } catch (e) {}
    return origFetch.call(window, input, init);
  };

  window.heroMemory = {
    list: load,
    clear: function () { localStorage.removeItem(LS); localStorage.removeItem(LS_TURN); },
    add: function (text) { var a = load(); a.push({ t: Date.now(), text: text }); save(a); }
  };
})();
