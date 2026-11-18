/* hero 记忆层 v2
 * 1) 读满再折：字数在预算内原样全带；超了就从最老的开始折叠（不删界面里的字）
 * 2) 她记得的事：每 N 轮抽取一小段事实，存本地，按相关度注入，有上限
 * 3) 每天收一次：当天的话压成几行「那天」，存本地
 * 4) 外观：藏掉「内容由 AI 生成」
 */
(function () {
  'use strict';

  var LS_MEM = 'hero.memory.v2';    // 她记得的事
  var LS_DAY = 'hero.days.v2';      // 一天一天的
  var LS_TURN = 'hero.turn.v2';
  var LS_LASTDAY = 'hero.lastday.v2';

  var MAX_CHARS = 900000;   // 对话正文预算
  var MAX_MEM = 60;         // 最多记 60 条
  var INJECT_MEM = 12;      // 每次最多注入 12 条
  var INJECT_CHARS = 900;
  var EXTRACT_EVERY = 6;
  var EXTRACT_MAX_TOK = 220;
  var DAY_MAX_TOK = 300;

  function loadArr(k) {
    try { var a = JSON.parse(localStorage.getItem(k) || '[]'); return Array.isArray(a) ? a : []; }
    catch (e) { return []; }
  }
  function saveArr(k, a) { try { localStorage.setItem(k, JSON.stringify(a)); } catch (e) {} }

  function textOf(c) {
    if (typeof c === 'string') return c;
    if (Array.isArray(c)) return c.map(function (x) { return x && x.text ? x.text : ''; }).join(' ');
    return '';
  }
  function charsOf(msgs) {
    var n = 0;
    for (var i = 0; i < msgs.length; i++) n += textOf(msgs[i].content).length;
    return n;
  }

  function grams(s) {
    var out = {}, i;
    for (i = 0; i + 1 < s.length; i++) {
      var g = s.substr(i, 2);
      if (/[\u4e00-\u9fa5a-zA-Z0-9]/.test(g)) out[g] = 1;
    }
    return out;
  }

  function pickMem(text) {
    var mem = loadArr(LS_MEM);
    if (!mem.length) return [];
    var g = grams(text || '');
    var scored = mem.map(function (m, i) {
      var mg = grams(m.text || ''), hit = 0, k;
      for (k in mg) if (g[k]) hit++;
      return { m: m, s: hit * 10 + i };
    });
    scored.sort(function (a, b) { return b.s - a.s; });
    var chosen = scored.slice(0, INJECT_MEM).map(function (x) { return x.m; });
    chosen.sort(function (a, b) { return (a.t || 0) - (b.t || 0); });
    var out = [], total = 0;
    for (var i = 0; i < chosen.length; i++) {
      var line = '· ' + chosen[i].text;
      if (total + line.length > INJECT_CHARS) break;
      total += line.length; out.push(line);
    }
    return out;
  }

  function daysBlock(n) {
    var d = loadArr(LS_DAY).slice(-(n || 5));
    if (!d.length) return '';
    return d.map(function (x) { return '· ' + x.date + '：' + x.text; }).join('\n');
  }

  function systemPrefix(latestUser, folded) {
    var out = '';
    var mem = pickMem(latestUser);
    if (mem.length) {
      out += '（这是她记得的事，只当背景，不要逐条复述，也不要用它改变说话方式）\n' + mem.join('\n') + '\n\n';
    }
    var days = daysBlock(folded ? 8 : 3);
    if (days) out += '（这些天的记录）\n' + days + '\n\n';
    return out;
  }

  function trim(body) {
    var msgs = body.messages || [];
    if (!msgs.length) return false;
    if (charsOf(msgs) <= MAX_CHARS) return false;
    var keep = msgs.slice();
    while (keep.length > 2 && charsOf(keep) > MAX_CHARS) keep.shift();
    while (keep.length && keep[0].role !== 'user') keep.shift();
    body.messages = keep;
    return true;
  }

  // ---------- 抽取：她记得的事 ----------
  var busy = false;
  function callApi(url, key, model, prompt, maxTok, cb) {
    fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key, 'x-hero-inner': '1' },
      body: JSON.stringify({
        model: model,
        system: '你是一个只做信息整理的助手，不做对话，不加评论。',
        messages: [{ role: 'user', content: [{ type: 'text', text: prompt }] }],
        thinking: { type: 'disabled' },
        tools: [],
        safety_check: { level: 'high' },
        max_tokens: maxTok,
        stream: false
      })
    }).then(function (r) { return r.text(); })
      .then(function (t) {
        var facts = [], re = /"text"\s*:\s*"((?:[^"\\]|\\.)*)"/g, m;
        while ((m = re.exec(t))) { try { facts.push(JSON.parse('"' + m[1] + '"')); } catch (e) {} }
        cb(facts.join('\n'));
      })
      .catch(function () { cb(''); });
  }

  function extractFacts(base, key, model, convo) {
    if (busy || !key || !convo) return;
    busy = true;
    var prompt = '从下面这段对话里提取 1~3 条以后还用得上的事实，每条一行以「- 」开头，不超过 30 字。' +
      '只写事实（人、事、约定、偏好、称呼、正在做的事），不写情绪评价，不复述原句，不写"用户说"。没有就只输出：无\n\n对话：\n' +
      convo.slice(-2500);
    callApi(base + '/anthropic/v1/messages', key, model, prompt, EXTRACT_MAX_TOK, function (txt) {
      var arr = loadArr(LS_MEM);
      txt.split('\n').forEach(function (l) {
        l = l.replace(/^[\s\-·•*]+/, '').trim();
        if (!l || l === '无' || l.length < 2 || l.length > 60) return;
        arr.push({ t: Date.now(), text: l });
      });
      while (arr.length > MAX_MEM) arr.shift();
      saveArr(LS_MEM, arr);
      busy = false;
    });
  }

  // ---------- 每天收一次 ----------
  function today() {
    var d = new Date();
    return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
  }

  function dailyDigest(base, key, model, convo) {
    var t = today(), last = localStorage.getItem(LS_LASTDAY);
    if (!convo) return;
    // 当天第一次说话时，把"昨天及以前"的收掉
    if (last && last !== t) {
      var days = loadArr(LS_DAY);
      if (days.length && days[days.length - 1].date === last && !days[days.length - 1].done) {
        var prompt = '把下面这一天里发生的事，用三到五行写下来，像日记，只写事实和说过的重要的话，不加评价。\n\n' +
          convo.slice(-6000);
        callApi(base + '/anthropic/v1/messages', key, model, prompt, DAY_MAX_TOK, function (txt) {
          var ds = loadArr(LS_DAY);
          if (ds.length) { ds[ds.length - 1].text = txt.trim(); ds[ds.length - 1].done = true; saveArr(LS_DAY, ds); }
        });
      }
    }
    if (last !== t) {
      var ds2 = loadArr(LS_DAY);
      ds2.push({ date: t, text: '', done: false });
      while (ds2.length > 400) ds2.shift();
      saveArr(LS_DAY, ds2);
      localStorage.setItem(LS_LASTDAY, t);
    }
  }

  // ---------- 拦截 fetch ----------
  var origFetch = window.fetch;
  if (!origFetch) return;
  window.fetch = function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('/anthropic/v1/messages') >= 0 && init && init.method === 'POST' && init.body) {
        var hdr = init.headers || {};
        var inner = hdr['x-hero-inner'] || hdr['X-Hero-Inner'];
        if (!inner) {
          var body = JSON.parse(init.body);
          if (!body.title) {
            var lastUser = '';
            for (var i = (body.messages || []).length - 1; i >= 0; i--) {
              var mm = body.messages[i];
              if (mm && mm.role === 'user') { lastUser = textOf(mm.content); break; }
            }
            var folded = trim(body);
            var pre = systemPrefix(lastUser, folded);
            if (pre) body.system = pre + (body.system || '');

            var key = hdr['x-api-key'] || hdr['X-Api-Key'] || '';
            var base = url.replace(/\/anthropic\/v1\/messages.*$/, '');
            var conv = '';
            (body.messages || []).slice(-8).forEach(function (m2) {
              var c = textOf(m2.content);
              if (c) conv += (m2.role === 'user' ? '我：' : '她：') + c + '\n';
            });
            dailyDigest(base, key, body.model, conv);
            var n = parseInt(localStorage.getItem(LS_TURN) || '0', 10) + 1;
            localStorage.setItem(LS_TURN, String(n));
            if (n % EXTRACT_EVERY === 0) extractFacts(base, key, body.model, conv);

            init = Object.assign({}, init, { body: JSON.stringify(body) });
          }
        }
      }
    } catch (e) {}
    return origFetch.call(window, input, init);
  };

  // ---------- 外观 ----------
  (function () {
    var st = document.createElement('style');
    st.textContent = '[class*="caveat-"]{display:none!important}';
    (document.head || document.documentElement).appendChild(st);
  })();

  window.heroMemory = {
    memories: function () { return loadArr(LS_MEM); },
    days: function () { return loadArr(LS_DAY); },
    forget: function () { localStorage.removeItem(LS_MEM); },
    add: function (text) { var a = loadArr(LS_MEM); a.push({ t: Date.now(), text: text }); saveArr(LS_MEM, a); }
  };
})();

// ---------- 输入框接管：页面里的输入框藏起来，改用 App 自己的 ----------
(function () {
  function findTa() { return document.querySelector('textarea'); }
  function containerOf() {
    var ta = findTa(); if (!ta) return null;
    var el = ta;
    for (var i = 0; i < 5 && el; i++) {
      el = el.parentElement;
      if (el && /textareaWrapper/.test(String(el.className))) return el;
    }
    return ta.parentElement;
  }
  function hide() {
    var c = containerOf();
    if (c) c.style.display = 'none';
    var ta = findTa();
    if (ta && document.activeElement === ta) ta.blur();
    return c ? 'hidden' : 'none';
  }
  function findSend() {
    var b = document.querySelector('button[aria-label="发送"]');
    if (b) return b;
    var all = document.querySelectorAll('button');
    for (var i = 0; i < all.length; i++) {
      if (/sendButton/.test(String(all[i].className))) return all[i];
    }
    return null;
  }
  function send(text) {
    var ta = findTa();
    if (!ta) return 'no-ta';
    var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
    setter.call(ta, text || '');
    ta.dispatchEvent(new Event('input', { bubbles: true }));
    ta.dispatchEvent(new Event('change', { bubbles: true }));
    setTimeout(function () {
      var b = findSend();
      if (b && !b.disabled) b.click();
      hide();
    }, 220);
    return 'ok';
  }
  document.addEventListener('DOMContentLoaded', function(){ setTimeout(hide, 60); });
  setInterval(hide, 3000);

  function vis(sel) {
    var e = document.querySelector(sel);
    return !!e && e.getBoundingClientRect().height > 10;
  }
  function state() {
    try {
      var ov = vis('[class*="overlay-"]') || vis('[class*="mask-"]') || vis('[class*="drawer-ac14ac"]');
      var editing = vis('[class*="textarea-ed6f47"]');
      return (ov || editing) ? '0' : '1';
    } catch (e) { return '1'; }
  }
  var last = null, timer = null;
  function push() {
    var s = state();
    if (s === last) return;
    last = s;
    try { if (window.HeroUI && window.HeroUI.postMessage) window.HeroUI.postMessage(s); } catch (e) {}
  }
  function watch() {
    if (watch.done) return;
    watch.done = true;
    var obs = new MutationObserver(function () { push(); });
    obs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class','style'] });
    document.addEventListener('click', function(){ push(); setTimeout(push, 30); setTimeout(push, 120); }, true);
    setInterval(push, 800);
    setTimeout(push, 60);
  }
  window.addEventListener('load', function(){ setTimeout(watch, 200); });
  window.heroInput = { hide: hide, send: send, state: state, watch: watch };
})();