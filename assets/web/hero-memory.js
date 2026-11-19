window.__topLoaded = true;
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
  var LS_PAST = 'hero.past.v1';     // 她记得的过去（内置）
  var LS_PASTSEED = 'hero.pastseed.v1';

  var MAX_CHARS = 1200000;  // 对话正文预算（约 80-100 万 token，留安全余量）
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

  // ---------- 内置的过去：第一次打开时把打包好的「她记得的日子」装进本地 ----------
  function seedPast() {
    try { if (localStorage.getItem(LS_PASTSEED) === '1') return; } catch (e) { return; }
    if (typeof fetch !== 'function') return;
    fetch('memory-seed.json', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (j) {
      var items = (j && j.items) || [];
      var arr = [];
      for (var i = 0; i < items.length; i++) {
        if (!items[i] || !items[i].m) continue;
        arr.push({ d: items[i].d || '', text: (items[i].d ? items[i].d + ' ' : '') + items[i].m });
      }
      if (arr.length) {
        saveArr(LS_PAST, arr);
        try { localStorage.setItem(LS_PASTSEED, '1'); } catch (e) {}
      }
    }).catch(function () {});
  }

  function pickPast(text) {
    var past = loadArr(LS_PAST);
    if (!past.length) return [];
    var g = grams(text || '');
    var scored = past.map(function (p, i) {
      var pg = grams(p.text || ''), hit = 0, k;
      for (k in pg) if (g[k]) hit++;
      return { p: p, s: hit, i: i };
    });
    scored.sort(function (a, b) { return (b.s - a.s) || (b.i - a.i); });
    var pick = scored.slice(0, 6).map(function (x) { return x.p; });
    pick.sort(function (a, b) { return (a.d || '') < (b.d || '') ? -1 : 1; });
    var out = [], total = 0;
    for (var i = 0; i < pick.length; i++) {
      var line = '· ' + pick[i].text;
      if (total + line.length > 800) break;
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
    var past = pickPast(latestUser);
    if (past.length) {
      out += '（她记得的过去，只当背景，不要逐条复述，也不要用它改变说话方式）\n' + past.join('\n') + '\n\n';
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
            // 关掉深度思考（免得每次都先想一大段才说话）
            body.thinking = { type: 'disabled' };

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
  function hide() { return; // 不再隐藏网页输入框
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
    }, 220);
    return 'ok';
  }


  function vis(sel) {
    var e = document.querySelector(sel);
    return !!e && e.getBoundingClientRect().height > 10;
  }
  function state() {
    try {
      var ov = vis('[class*="overlay-"]') || vis('[class*="mask-"]') || vis('[class*="drawer-ac14ac"]');
      var editing = vis('[class*="textarea-ed6f47"]');
      try { document.body.classList.toggle('hero-drawer', ov); } catch (e) {}
      return (ov || editing) ? '0' : '1';
    } catch (e) { return '1'; }
  }
  var last = null, timer = null;
  function push() {
    var s = state();
    if (s === last) return;
    last = s;
    try { if (window.HeroUI && window.HeroUI.postMessage) window.HeroUI.postMessage('M:' + s); } catch (e) {}
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
/* ---------- heroDrawer：让 App 自己画侧栏 ---------- */
(function(){
  function post(m){ try { if (window.HeroUI && window.HeroUI.postMessage) window.HeroUI.postMessage(m); } catch(e){} }
  function drawerEl(){ return document.querySelector('[class*="drawer-ac14ac"]'); }
  function isOpen(){
    var d = drawerEl();
    if (!d) return false;
    var r = d.getBoundingClientRect();
    return r.width > 10 && r.right > 10;
  }
  function toggleBtn(){
    var a = document.querySelector('button[aria-label="打开边栏"]');
    if (a) return a;
    return document.querySelector('button[aria-label="收起边栏"]');
  }
  function openDrawer(cb){
    if (isOpen()) { cb(); return; }
    var b = document.querySelector('button[aria-label="打开边栏"]');
    if (!b) { cb(); return; }
    b.click();
    setTimeout(cb, 320);
  }
  function closeDrawer(){
    var b = document.querySelector('button[aria-label="收起边栏"]');
    if (b) b.click();
  }
  function collect(){
    var d = drawerEl();
    if (!d) return [];
    var out = [];
    var nodes = d.querySelectorAll('button,[role="button"],a,div');
    for (var i = 0; i < nodes.length; i++) {
      var e = nodes[i];
      var cls = String(e.className);
      if (cls.indexOf('newChat-') >= 0 || cls.indexOf('settings-') >= 0) continue;
      if (e.children.length > 0) continue;
      var txt = (e.textContent || '').trim();
      if (!txt || txt.length > 60) continue;
      out.push({ i: out.length, t: txt, el: e });
    }
    return out;
  }
  var cache = [];
  var heroDrawer = {
    scan: function(){
      openDrawer(function(){
        var items = collect();
        cache = items.map(function(x){ return { i: x.i, t: x.t }; });
        window.__heroItems = items;
        post('S:' + JSON.stringify(cache));
        setTimeout(function(){ if (!window.__heroKeepOpen) closeDrawer(); }, 60);
      });
      return 'scanning';
    },
    open: function(i){
      openDrawer(function(){
        var items = window.__heroItems || collect();
        window.__heroItems = items;
        if (items[i] && items[i].el) items[i].el.click();
        setTimeout(closeDrawer, 120);
      });
      return 'ok';
    },
    newChat: function(){
      var b = document.querySelector('.newChat-ac14ac');
      if (b) b.click();
      return 'ok';
    },
    settings: function(){
      var b = document.querySelector('.settings-ac14ac');
      if (b) b.click();
      return 'ok';
    },
    close: function(){ closeDrawer(); return 'ok'; }
  };
  window.heroDrawer = heroDrawer;
})();
/* ===== 把她的过去搬进来（库空时执行一次，逐个会话写入） ===== */
(function heroSeed(){
  const DB='chat-demo', VER=11;
  function open(){
    return new Promise((res,rej)=>{
      const r=indexedDB.open(DB,VER);
      r.onupgradeneeded=()=>{
        const db=r.result;
        ['sessions','files','sessionsStaging','filesStaging'].forEach(n=>{
          if(!db.objectStoreNames.contains(n)) db.createObjectStore(n,{keyPath:'id'});
        });
        let st;
        if(!db.objectStoreNames.contains('sessionSummaries')) st=db.createObjectStore('sessionSummaries',{keyPath:'id'});
        if(st && !st.indexNames.contains('fileIds')) st.createIndex('fileIds','fileIds',{multiEntry:true});
      };
      r.onsuccess=()=>res(r.result);
      r.onerror=()=>rej(r.error);
    });
  }
  function count(db){
    return new Promise(res=>{
      try{ const q=db.transaction('sessions','readonly').objectStore('sessions').count();
        q.onsuccess=()=>res(q.result); q.onerror=()=>res(0); }catch(e){ res(0); }
    });
  }
  function put(db, sess){
    return new Promise((res,rej)=>{
      const tx=db.transaction(['sessions','sessionSummaries'],'readwrite');
      tx.oncomplete=()=>res(); tx.onerror=()=>rej(tx.error);
      tx.objectStore('sessions').put(sess);
      tx.objectStore('sessionSummaries').put({id:sess.id,title:sess.title,createdAt:sess.createdAt,updatedAt:sess.updatedAt,fileIds:[]});
    });
  }
  async function run(){
    try{
      const flag=localStorage.getItem('hero.seeded.v2');
      const idxRes=await fetch('history/index.json',{cache:'no-store'});
      if(!idxRes.ok) return;
      const idx=await idxRes.json();
      const items=idx.items||[];
      const db=await open();
      if(flag && flag===String(items.length)) return;
      const done=flag ? flag.split(',').filter(Boolean) : [];
      let moved=0;
      for(const it of items){
        if(done.indexOf(it.id)>=0) continue;
        if(moved>=25) break;
        try{
          const r=await fetch(it.file,{cache:'no-store'});
          if(!r.ok) continue;
          const data=await r.json();
          for(const sess of (data.sessions||[])) await put(db,sess);
          done.push(it.id);
          localStorage.setItem('hero.seeded.v2', done.join(','));
          moved++;
          await new Promise(r=>setTimeout(r,120));
          console.log('[hero] 搬进来：'+it.title);
          try{ if(window.HeroUI&&HeroUI.postMessage) HeroUI.postMessage('SEED:'+moved+'/'+items.length); }catch(e){}
        }catch(e){ console.warn('[hero] skip '+it.id, e); }
      }
      if(moved>0){
        try{ if(window.HeroUI&&HeroUI.postMessage) HeroUI.postMessage('DONE:'+moved); }catch(e){}
      }
    }catch(e){ console.warn('[hero] seed failed',e); }
  }
  /* 自动搬运已停用：改用官方「导入历史对话」 */
})();
/* ===== 每天一次：把当天有更新的会话传到电脑（覆盖上一次） ===== */
(function heroSync(){
  const KEY='hero.sync.date', URLKEY='hero.sync.url';
  const def='http://192.168.71.7:8092/sync';
  function today(){ const d=new Date(); return d.getFullYear()+'-'+(d.getMonth()+1)+'-'+d.getDate(); }
  function openDB(){
    return new Promise((res,rej)=>{
      const r=indexedDB.open('chat-demo',11);
      r.onsuccess=()=>res(r.result); r.onerror=()=>rej(r.error);
      r.onupgradeneeded=()=>{};
    });
  }
  function all(db){
    return new Promise((res,rej)=>{
      try{ const q=db.transaction('sessions','readonly').objectStore('sessions').getAll();
        q.onsuccess=()=>res(q.result||[]); q.onerror=()=>rej(q.error); }catch(e){ rej(e); }
    });
  }
  async function run(){
    try{
      if(localStorage.getItem(KEY)===today()) return;
      const db=await openDB();
      const list=await all(db);
      if(!list.length) return;
      const url=localStorage.getItem(URLKEY)||def;
      const since=Date.now()-36*3600*1000;
      let ok=0;
      for(const s of list){
        if((s.updatedAt||0) < since) continue;
        try{
          await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:s.id,title:s.title,createdAt:s.createdAt,updatedAt:s.updatedAt,messages:s.messages})});
          ok++;
        }catch(e){}
      }
      if(ok>0){ localStorage.setItem(KEY,today()); console.log('[hero] 今天已传到电脑 '+ok+' 个会话'); }
    }catch(e){ console.warn('[hero] sync failed',e); }
  }
  /* 自动搬运已停用：改用官方「导入历史对话」 */
  // ---------- 首次启动：把内置的「希罗」会话导入（用官方导入流程，排列一定对） ----------
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function clickByText(txt) {
    var all = [].slice.call(document.querySelectorAll('button,[role=button],a,div,span'));
    for (var i = all.length - 1; i >= 0; i--) {
      var e = all[i];
      if (e.children.length === 0 && (e.textContent || '').trim() === txt) { e.click(); return true; }
    }
    return false;
  }
  function countSessions() {
    return new Promise(function (res) {
      try {
        var rq = indexedDB.open('chat-demo');
        rq.onsuccess = function () {
          var db = rq.result;
          try {
            var tr = db.transaction('sessions', 'readonly');
            var c = tr.objectStore('sessions').count();
            c.onsuccess = function () { res(c.result || 0); };
            c.onerror = function () { res(-1); };
          } catch (e) { res(-1); }
        };
        rq.onerror = function () { res(-1); };
      } catch (e) { res(-1); }
    });
  }
  async function autoImportSeed() {
    try { if (localStorage.getItem('hero.seed.imported') === '1') return; } catch (e) { return; }
    var n = await countSessions();
    if (n > 0) { try { localStorage.setItem('hero.seed.imported', '1'); } catch (e) {} return; }
    try {
      var resp = await fetch('hero-seed.zip');
      if (!resp.ok) return;
      var blob = await resp.blob();
      var file = new File([blob], 'hero-seed.zip', { type: 'application/zip' });
      // 打开设置 → 数据管理 → 找到那个只接受 .zip 的输入框
      clickByText('设置') || clickByText('打开边栏');
      await sleep(500);
      clickByText('设置');
      await sleep(500);
      clickByText('数据管理');
      await sleep(600);
      var inp = [].slice.call(document.querySelectorAll('input[type=file]')).filter(function (i) {
        return /zip/i.test(i.accept || '');
      })[0];
      if (!inp) { console.warn('[hero] 没找到导入输入框'); return; }
      var dt = new DataTransfer();
      dt.items.add(file);
      inp.files = dt.files;
      inp.dispatchEvent(new Event('change', { bubbles: true }));
      try { localStorage.setItem('hero.seed.imported', '1'); } catch (e) {}
      console.log('[hero] 已导入内置会话');
    } catch (e) { console.warn('[hero] autoImport failed', e); }
  }
  try { window.heroAutoImport = autoImportSeed; } catch (e) {}
  /* 装内置的过去（只装一次） */
  try { seedPast(); } catch (e) { console.warn('[hero] seedPast failed', e); }
  setTimeout(function () { try { autoImportSeed(); } catch (e) {} }, 2500);

})();

/* ================= heroPage: 会话分窗（只把最近 N 条交给页面） ================= */
(function () {
  window.__heroPageLoaded = true;
  if (window.heroPage) return;
  var DEFAULT_WIN = 200;
  var full = Object.create(null);   // id -> 完整 messages
  var lastId = null;
  var pendingPut = false;
  var KEY = function (id) { return 'hero.win.' + id; };
  function win(id) { var v = parseInt(localStorage.getItem(KEY(id)) || '', 10); return isNaN(v) ? DEFAULT_WIN : v; }

  function db(cb) {
    var r = indexedDB.open('chat-demo');
    r.onsuccess = function () { cb(r.result); };
    r.onerror = function () { };
  }

  // 只读全量（用于首次进入某会话时把完整历史取回来）
  function loadFull(id, cb) {
    if (full[id]) { cb(full[id]); return; }
    db(function (d) {
      try {
        var tx = d.transaction('sessions', 'readonly');
        var g = tx.objectStore('sessions').get(id);
        g.onsuccess = function () {
          var s = g.result;
          if (s && s.messages) { full[id] = s.messages.slice(); }
          cb(full[id] || []);
        };
        g.onerror = function () { cb([]); };
      } catch (e) { cb([]); }
    });
  }

  // 包一层 get / put：读的时候只给窗口，写的时候把老消息接回去，保证不丢
  try {
    var proto = IDBObjectStore.prototype;
    var og = proto.get, op = proto.put;
    proto.get = function (q) {
      var req = og.apply(this, arguments);
      if (this.name === 'sessions') {
        req.addEventListener('success', function () {
          var s = req.result;
          if (!s || !s.messages || !s.messages.length) return;
          var id = s.id; lastId = id;
          var total = s.messages.length;
          if (total > win(id)) {
            full[id] = s.messages.slice();
            var cut = s.messages.slice(total - win(id));
            // 只能改 result 对象本身
            s.messages = cut;
            window.__heroTrim = { id: id, total: total, shown: cut.length };
            setTimeout(paintBanner, 0);
          } else if (full[id] && full[id].length > total) {
            // 已加载过全量，但库里的也已经是窗口了：保持
          }
        }, true);
      }
      return req;
    };
    proto.put = function (v) {
      try {
        if (this.name === 'sessions' && v && v.id && full[v.id] && v.messages && v.messages.length < full[v.id].length) {
          var keep = full[v.id].length - v.messages.length;
          if (keep > 0) {
            var merged = full[v.id].slice(0, keep).concat(v.messages);
            full[v.id] = merged;
            v = Object.assign({}, v, { messages: merged });
            arguments[0] = v;
          }
        }
      } catch (e) { }
      return op.apply(this, arguments);
    };
  } catch (e) { }

  // 顶部小条：还有更早的
  var bar = null;
  function paintBanner() {
    var t = window.__heroTrim;
    if (!t) return;
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'hero-more';
      bar.style.cssText = 'position:fixed;left:50%;transform:translateX(-50%);top:8px;z-index:2147483000;' +
        'background:#2C2C2E;color:#F9FAFB;font:13px/1.4 -apple-system,system-ui;padding:7px 14px;border-radius:14px;' +
        'box-shadow:0 2px 10px rgba(0,0,0,.4);cursor:pointer;opacity:.92';
      document.body.appendChild(bar);
      bar.addEventListener('click', function () {
        var id = t.id;
        localStorage.setItem(KEY(id), String(win(id) + DEFAULT_WIN));
        location.reload();
      });
      setTimeout(function () { if (bar) bar.style.transition = 'opacity .4s'; }, 2500);
      setTimeout(function () { if (bar) bar.style.opacity = '0.25'; }, 6000);
    }
    var older = t.total - t.shown;
    bar.textContent = '更早还有 ' + older + ' 条 · 点这里往上加载';
    bar.style.display = 'block';
  }

  window.heroPage = {
    win: win,
    more: function (id) { localStorage.setItem(KEY(id || lastId), String(win(id || lastId) + DEFAULT_WIN)); location.reload(); },
    reset: function (id) { localStorage.removeItem(KEY(id || lastId)); },
    info: function () { return { last: lastId, trim: window.__heroTrim || null }; }
  };
})();
window.__endLoaded = true;
