#!/usr/bin/env node
// Browser regressions for native DOM discovery. Uses an isolated headless
// profile and synthetic pages; it never connects to the user's Codex renderer.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const chrome = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'autoskin-adapter-'));
const child = spawn(chrome, ['--headless=new', '--no-first-run', '--no-default-browser-check',
  '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'],
{ stdio: 'ignore' });
let launchError;
child.on('error', error => { launchError = error; });
let socket;
try {
  let port;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (launchError) throw launchError;
    try { port = Number((await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]); } catch {}
    if (port) break;
    await delay(100);
  }
  assert.ok(port, 'isolated headless Chrome did not start (set CHROME_BIN)');
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let nextId = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(String(event.data));
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message));
    else waiter.resolve(message.result);
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result?.value;
  };
  await send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 900, deviceScaleFactor: 1, mobile: false });
  const css = (await fs.readFile(path.join(root, 'styles/dream/style.css'), 'utf8')) +
    '\n:root.codex-dream-skin { --dream-composer-placeholder: "在清凉水花里写下你的想法…"; }';
  const template = await fs.readFile(path.join(root, 'assets/renderer-inject.js'), 'utf8');
  const art = 'data:image/svg+xml;base64,' + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="skyblue"/></svg>').toString('base64');
  const manifest = { order: ['test'], defaultTheme: 'test', defaultLayout: 'fullscreen',
    meta: { test: { brand: 'Test', edition: 'Adapter', signature: 'QA' } },
    decorations: { test: [{kind:'text',surface:'home',position:[.9,.2],opacity:.5,size:12,color:'#abcdef',value:'♡'}] } };
  const payload = template.replace('__DREAM_CSS_JSON__', () => JSON.stringify(css))
    .replace('__DREAM_ART_ASSETS_JSON__', () => JSON.stringify({ test: { home: art, chat: art } }))
    .replace('__DREAM_MANIFEST_JSON__', () => JSON.stringify(manifest));
  const editor = '<div id="composer" class="native-composer"><div class="ProseMirror" role="textbox" contenteditable="true"><p class="placeholder" data-placeholder="Do anything"><br></p></div><button>Send</button></div>';
  const hero = '<div id="hero-frame"><div><div><h1 data-feature="game-source">What should we build?</h1></div><section class="group/home-suggestions"><button>First card</button><button>Second card</button></section></div></div>';
  const codex = `<div role="main" class="home-main-content"><div class="layout"><div class="contents">${hero}<div class="dock"><div>${editor}</div></div></div></div></div>`;
  const chat = mode => `<div class="chat-frame"><div class="mode-row"><div role="group" aria-label="Composer mode"><button aria-pressed="${mode === 'chat'}">Chat</button><button aria-pressed="${mode === 'work'}">Work</button></div></div><div role="main" class="home-main-content"><div class="layout"><div><h1 ${mode === 'work' ? 'data-feature="game-source"' : ''}>Hello</h1></div><div class="dock">${editor}<section class="group/home-suggestions"><button>Suggestion one</button><button>Suggestion two</button></section></div></div></div></div>`;
  const conversation = editable => `<div role="main" class="thread"><div role="region" aria-label="Conversation" data-app-action-timeline-scroll><div data-thread-find-target="conversation"><p>A rendered response without article or author-role markers.</p></div></div>${editable ? editor : '<div>This is open in another app</div>'}</div>`;
  const setup = async content => {
    const fixture = `<style>
      *{box-sizing:border-box} html,body{margin:0;height:100%;overflow:hidden}
      body{display:flex;padding-top:44px}
      aside{position:relative;width:240px;height:100%}
      main{position:relative;width:calc(100% - 240px);height:100%}
      header{position:fixed;top:0;left:0;width:100%;height:44px}
      .home-main-content,.thread{height:100%;position:relative;container-type:size}
      .layout{display:flex;flex-direction:column;height:100%}.contents{display:contents}
      #hero-frame{flex:1} h1{font-size:32px}section{display:flex;gap:12px}section button{width:180px;height:80px}
      .dock{flex:1}.native-composer{width:80%;height:100px;margin:0 auto;border-radius:20px;background:white;position:relative}
      [role=textbox]{height:48px}.chat-frame{position:relative;height:100%;display:flex;flex-direction:column}
      p.placeholder::before{content:attr(data-placeholder);position:absolute;pointer-events:none}
      .chat-frame .home-main-content{flex:1;min-height:0}.chat-frame .layout{justify-content:center}
      .chat-frame .dock{flex:none}.mode-row{height:46px;flex:none;display:flex;align-items:center;justify-content:center}
      [aria-label="Composer mode"]{height:30px} [aria-label="Composer mode"] button{height:30px;width:80px}
      .thread{display:flex;flex-direction:column;justify-content:space-between;padding:20px}
    </style><header></header><aside><nav><button>Home</button><button>New task</button><button>Settings</button></nav>
      <button id="usage-trigger" aria-label="Usage" aria-description="Native usage information" aria-describedby="native-help"
        style="position:absolute;left:8px;bottom:60px;width:36px;height:36px"><span id="native-usage-icon">◉</span></button>
      <span id="native-help" hidden>Native help</span></aside><main>${content}</main>`;
    await evaluate(`window.__CODEX_DREAM_SKIN_STATE__?.cleanup();document.body.innerHTML=${JSON.stringify(fixture)};true`);
    await evaluate(`window.nativeUsageClicks=0;document.querySelector('#usage-trigger').addEventListener('click',()=>{window.nativeUsageClicks++;});true`);
    await evaluate(payload);
  };
  const snapshot = () => evaluate(`(() => {
    const state=window.__CODEX_DREAM_SKIN_STATE__, c=document.querySelector('.dream-composer-surface');
    const frame=document.querySelector('.dream-chat-home-frame'), toggle=document.querySelector('.dream-home-mode-toggle');
    const p=document.querySelector('.ProseMirror p[data-placeholder]');
    const r=c?.getBoundingClientRect();
    return {surface:state.adapter.signals.surface,readOnly:state.adapter.signals.readOnly,
      composer:c?.id ?? null,box:r?[r.x,r.y,r.width,r.height]:null,scheduled:Boolean(state.scheduler.timeout),
      home:document.querySelectorAll('.dream-home').length,parts:document.querySelectorAll('.dream-home-dock').length,
      workCanvasTop:document.querySelector('.dream-work-home-frame') ?
        getComputedStyle(document.querySelector('.dream-work-home-frame'),'::before').top : null,
      placeholder:p?[getComputedStyle(p,'::before').content,getComputedStyle(p,'::after').content]:null,
      frameContainsToggle:Boolean(frame&&toggle&&frame.contains(toggle)),
      toggleHit:!toggle||[...toggle.querySelectorAll('button')].every(b=>{const r=b.getBoundingClientRect();return b.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));})};
  })()`);
  for (const [name, html, expected] of [
    ['Codex home with display:contents', codex, 'work-home'],
    ['ChatGPT Work with shared home markers', chat('work'), 'chat-home'],
    ['ChatGPT Chat with shared suggestions', chat('chat'), 'chat-home'],
    ['conversation without legacy message attributes', conversation(true), 'conversation'],
    ['read-only conversation', conversation(false), 'conversation'],
    ['utility page', '<div><h1>Plugins</h1><p>Browse available tools.</p></div>', 'utility'],
  ]) {
    await setup(html);
    const first = await snapshot();
    assert.equal(first.surface, expected, name);
    if (expected === 'conversation') assert.equal(await evaluate(`getComputedStyle(document.querySelector('.dream-autoskin-decoration')).display`),
      'none', 'home decorations must be hidden on conversation surfaces');
    if (expected === 'work-home') assert.equal(first.workCanvasTop, '8px', 'Codex canvas must reach the main pane top');
    if (expected.endsWith('-home')) assert.deepEqual(first.placeholder,
      ['"在清凉水花里写下你的想法…"', 'none'], 'home must show one Chinese hint without duplicate English');
    if (name === 'read-only conversation') assert.equal(first.readOnly, true, name);
    if (expected !== 'utility' && !first.readOnly) assert.equal(first.composer, 'composer', name);
    if (expected === 'chat-home') {
      assert.equal(first.home, 0, name);
      assert.equal(first.parts, 0, name);
      assert.ok(first.frameContainsToggle && first.toggleHit, name);
    }
    // Force successive discovery passes, then let the real MutationObserver
    // run. Neither discovery feedback nor our own writes may move the editor.
    await evaluate(`for(let i=0;i<8;i++)window.__CODEX_DREAM_SKIN_STATE__.ensure();true`);
    await delay(750);
    const settled = await snapshot();
    assert.deepEqual(settled.box, first.box, `${name}: layout drift`);
    assert.equal(settled.scheduled, false, `${name}: self-triggered observer loop`);
    console.log(`PASS ${name}`);
  }
  const attachmentComposer = editor.replace('class="native-composer"', 'class="native-composer attachment-composer"')
    .replace('<div class="ProseMirror"', '<div role="img" aria-label="Image attachment" style="width:120px;height:120px"></div><div class="ProseMirror"');
  for (const layout of ['fullscreen', 'banner']) {
    await setup(`${codex.replace(editor, attachmentComposer)}<style>
      .attachment-composer{width:min(100%, var(--thread-content-max-width, 736px));height:220px}
    </style>`);
    await evaluate(`window.__CODEX_DREAM_SKIN_STATE__.setLayout(${JSON.stringify(layout)});true`);
    const empty = await snapshot();
    assert.equal(empty.surface, 'work-home');
    assert.ok(empty.box[2] > 736, `${layout}: fixture must start with the wider Work composer`);
    await evaluate(`(() => {
      document.querySelector('.ProseMirror').addEventListener('input', () => {
        document.querySelector('[class*="home-suggestions"]')?.remove();
      }, {once: true});
      document.querySelector('.ProseMirror').focus();
      return true;
    })()`);
    await send('Input.insertText', {text: '帮我'});
    await delay(350);
    const typed = await snapshot();
    assert.equal(typed.surface, 'work-home', `${layout}: removing suggestions must retain the Work home`);
    assert.deepEqual([typed.box[0], typed.box[2]], [empty.box[0], empty.box[2]], `${layout}: typing must preserve width and alignment`);
    assert.equal(await evaluate(`document.querySelector('.ProseMirror').textContent`), '帮我');
    assert.equal(await evaluate(`document.querySelectorAll('#composer [role="img"]').length`), 1);
    await evaluate(`document.querySelector('[role="main"]').insertAdjacentHTML('afterbegin',
      '<section role="region" aria-label="Conversation"><p>A real message</p></section>');true`);
    await delay(350);
    const thread = await snapshot();
    assert.equal(thread.surface, 'conversation', 'a visible conversation must supersede the retained Work home');
    assert.equal(thread.box[2], 736, 'the thread must use its own composer width');
  }
  console.log('PASS composer width while typing with an attachment');
  await evaluate(`window.__CODEX_DREAM_SKIN_STATE__.setLayout('fullscreen');true`);
  await setup(conversation(true) + `<div hidden>${codex}</div>`);
  assert.equal((await snapshot()).surface, 'conversation', 'hidden home must not replace a conversation');
  await evaluate(`document.querySelector('.dream-main-surface').className='native-main';true`);
  await delay(350);
  assert.equal(await evaluate(`Boolean(document.querySelector('main.dream-main-surface'))`), true, 'native class replacement must restore markers');
  await evaluate(`document.querySelector('main').innerHTML=${JSON.stringify(chat('work'))};true`);
  await delay(350);
  assert.equal((await snapshot()).surface, 'chat-home', 'native navigation must refresh markers');
  await evaluate(`document.querySelector('main').innerHTML=${JSON.stringify(codex)};true`);
  await delay(350);
  assert.equal((await snapshot()).surface, 'work-home', 'return navigation must refresh markers');
  assert.equal(await evaluate(`document.querySelectorAll('.dream-chat-home-frame,.dream-home-mode-toggle').length`), 0, 'chat markers must be removed after navigation');
  console.log('PASS hidden homes, native class replacement, and navigation');
  // React replaces className on mounted native nodes. The home width and
  // composer skin must survive that commit before the next paint, rather
  // than flashing back to native geometry for the debounced refresh delay.
  const beforeNativeCommit = await snapshot();
  await evaluate(`(() => {
    document.querySelector('.dream-home').className='home-main-content';
    document.querySelector('#composer').className='native-composer';
    return true;
  })()`);
  const afterNativeCommit = await snapshot();
  assert.equal(afterNativeCommit.home, 1, 'native class replacement must restore home markers before paint');
  assert.equal(afterNativeCommit.composer, 'composer', 'native class replacement must restore composer before paint');
  assert.deepEqual(afterNativeCommit.box, beforeNativeCommit.box, 'native commits must not expose an unskinned composer');
  assert.equal(afterNativeCommit.scheduled, false, 'immediate restoration must cancel the pending debounced refresh');
  console.log('PASS native class replacement without a debounced layout flash');
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.dream-suggestion-card'), n=>n.dataset.dreamCardIndex)`),
    ['1', '2'], 'native suggestion buttons need stable theme indices without grid class assumptions');
  for (const label of ['New task', 'New chat', '新建对话']) {
    await evaluate(`(() => {const b=document.querySelector('aside nav button:nth-child(2)');b.textContent=${JSON.stringify(label)};
      const history=document.createElement('button');history.id='history';history.textContent='New chat architecture review';
      document.querySelector('aside nav').append(history);window.__CODEX_DREAM_SKIN_STATE__.ensure();return true;})()`);
    assert.equal(await evaluate(`document.querySelector('.dream-new-task')?.textContent`), label);
    assert.equal(await evaluate(`document.querySelector('#history').classList.contains('dream-new-task')`), false,
      'a thread title containing New chat must never become the new-chat capsule');
    await evaluate(`document.querySelector('#history').remove();true`);
  }
  console.log('PASS current new-chat labels and stable suggestion indices');
  await evaluate(`document.querySelector('.dream-composer-surface').insertAdjacentHTML('beforeend','<span class="dream-usage-orb"></span>');window.__CODEX_DREAM_SKIN_STATE__.ensure();true`);
  assert.equal(await evaluate(`document.querySelectorAll('.dream-usage-orb').length`), 1);
  assert.equal(await evaluate(`document.querySelector('.dream-usage-orb').parentElement.id`), 'usage-trigger');
  assert.equal(await evaluate(`document.querySelectorAll('.dream-composer-surface .dream-usage-orb').length`), 0);
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#native-usage-icon')).visibility`), 'hidden');
  assert.equal(await evaluate(`document.querySelector('.dream-usage-orb').hasAttribute('tabindex')`), false);
  assert.equal(await evaluate(`(()=>{const b=document.querySelector('#usage-trigger'),r=b.getBoundingClientRect();
    return b.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));})()`), true,
    'native button must remain the hit target under the custom orb');
  await send('Emulation.setFocusEmulationEnabled', {enabled:true});
  await evaluate(`document.querySelector('#usage-trigger').focus();true`);
  assert.equal(await evaluate(`document.querySelector('#codex-dream-skin-usage-tooltip')?.parentElement===document.body`), true,
    'tooltip must escape the clipped sidebar');
  assert.equal(await evaluate(`document.querySelector('#codex-dream-skin-usage-tooltip').hidden`), false);
  await send('Input.dispatchKeyEvent', {type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32});
  await send('Input.dispatchKeyEvent', {type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32});
  assert.equal(await evaluate(`window.nativeUsageClicks`), 1, 'keyboard activation must retain the native action');
  assert.equal(await evaluate(`document.querySelector('#codex-dream-skin-usage-tooltip').hidden`), true);
  await evaluate(`document.querySelector('#usage-trigger').innerHTML='<span id="native-usage-icon">◉</span>';window.__CODEX_DREAM_SKIN_STATE__.ensure();true`);
  assert.equal(await evaluate(`document.querySelectorAll('#usage-trigger .dream-usage-orb').length`), 1,
    'native rerenders must restore exactly one orb');
  assert.equal(await evaluate(`document.querySelector('#usage-trigger').getAttribute('aria-description')`), 'Native usage information');
  console.log('PASS native usage placement, keyboard action, tooltip portal and rerender');
  await evaluate(`(() => {const p=document.querySelector('.ProseMirror p');p.removeAttribute('data-placeholder');p.classList.remove('placeholder');p.textContent='Keep this draft';window.__CODEX_DREAM_SKIN_STATE__.ensure();return true;})()`);
  assert.equal(await evaluate(`document.querySelector('.ProseMirror').textContent`), 'Keep this draft', 'placeholder styling must preserve typed content');
  console.log('PASS Chinese placeholder and draft preservation');
  await evaluate('window.__CODEX_DREAM_SKIN_STATE__.cleanup();true');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#native-usage-icon')).visibility`), 'visible');
  assert.equal(await evaluate(`document.querySelector('#usage-trigger').getAttribute('aria-describedby')`), 'native-help');
  assert.equal(await evaluate(`document.querySelector('#codex-dream-skin-usage-tooltip')`), null);
  await evaluate(`document.querySelector('#usage-trigger').click();true`);
  assert.equal(await evaluate(`window.nativeUsageClicks`), 2, 'cleanup must restore the original control without replacing its handler');
  assert.equal(await evaluate(`document.querySelectorAll('[class*="dream-"]').length`), 0, 'cleanup must remove all markers');
  console.log('PASS cleanup');
} finally {
  socket?.close();
  if (child.exitCode === null && !launchError) {
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.kill();
    await exited;
  }
  await fs.rm(profile, { recursive: true, force: true });
}
