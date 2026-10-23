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
    meta: { test: { brand: 'Test', edition: 'Adapter', signature: 'QA' } } };
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
    </style><header></header><aside><nav><button>Home</button><button>New task</button><button>Settings</button></nav></aside><main>${content}</main>`;
    await evaluate(`window.__CODEX_DREAM_SKIN_STATE__?.cleanup();document.body.innerHTML=${JSON.stringify(fixture)};true`);
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
  await evaluate(`(() => {const p=document.querySelector('.ProseMirror p');p.removeAttribute('data-placeholder');p.classList.remove('placeholder');p.textContent='Keep this draft';window.__CODEX_DREAM_SKIN_STATE__.ensure();return true;})()`);
  assert.equal(await evaluate(`document.querySelector('.ProseMirror').textContent`), 'Keep this draft', 'placeholder styling must preserve typed content');
  console.log('PASS Chinese placeholder and draft preservation');
  await evaluate('window.__CODEX_DREAM_SKIN_STATE__.cleanup();true');
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
