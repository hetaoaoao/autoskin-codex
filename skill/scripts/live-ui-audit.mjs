#!/usr/bin/env node

// Read-only live regression audit for the currently visible Codex surface.
// It never submits a composer or mutates conversations. The script temporarily
// emulates several viewport sizes and both AutoSkin layouts, then restores the
// renderer exactly as it found it.

function parseArgs(argv) {
  const options = {
    port: 9335,
    sizes: [[1708, 977], [1180, 820], [900, 760], [720, 700]],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--sizes") {
      options.sizes = argv[++index].split(",").map((item) => {
        const match = /^(\d+)x(\d+)$/.exec(item);
        if (!match) throw new Error(`Invalid viewport: ${item}`);
        return [Number(match[1]), Number(match[2])];
      });
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error(`Invalid port: ${options.port}`);
  }
  return options;
}

function isMainRendererTarget(target) {
  try {
    const url = new URL(target.url);
    return target.type === "page" && url.protocol === "app:" && url.hostname === "-" &&
      url.pathname === "/index.html" && !url.searchParams.has("initialRoute");
  } catch {
    return false;
  }
}

async function findTarget(port) {
  let lastError;
  for (const host of ["127.0.0.1", "[::1]"]) {
    try {
      const response = await fetch(`http://${host}:${port}/json/list`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const target = (await response.json()).find(isMainRendererTarget);
      if (target) return target;
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error(`No main Codex renderer on port ${port}: ${lastError?.message ?? "not found"}`);
}

class Session {
  constructor(target) {
    this.socket = new WebSocket(target.webSocketDebuggerUrl);
    this.pending = new Map();
    this.nextId = 1;
  }

  async open() {
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", resolve, { once: true });
      this.socket.addEventListener("error", reject, { once: true });
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (!message.id) return;
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(message.error.message));
      else waiter.resolve(message.result);
    });
    await this.send("Runtime.enable");
    return this;
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (response.exceptionDetails) throw new Error(
      response.exceptionDetails.exception?.description ?? response.exceptionDetails.text);
    return response.result?.value;
  }

  close() {
    this.socket.close();
  }
}

const auditExpression = `(async () => {
  const visible = (node) => {
    if (!node || !node.isConnected || !node.getClientRects().length) return false;
    if (node.closest('[hidden], [aria-hidden="true"], [inert]')) return false;
    const style = getComputedStyle(node);
    const rect = node.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) !== 0 &&
      rect.width > 1 && rect.height > 1 && rect.bottom > 0 && rect.right > 0 &&
      rect.top < innerHeight && rect.left < innerWidth;
  };
  const first = (selector, root = document) => [...root.querySelectorAll(selector)].find(visible) ?? null;
  const box = (node) => {
    if (!node) return null;
    const rect = node.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      right: rect.right, bottom: rect.bottom };
  };
  const intersection = (left, right) => left && right ?
    Math.max(0, Math.min(left.right, right.right) - Math.max(left.x, right.x)) *
    Math.max(0, Math.min(left.bottom, right.bottom) - Math.max(left.y, right.y)) : 0;
  const state = window.__CODEX_DREAM_SKIN_STATE__;
  const workHome = first('.dream-home');
  const chatHome = first('.dream-chat-home');
  const chatFrame = first('.dream-chat-home-frame');
  const composerNode = first('.composer-surface-chrome, .dream-composer-surface');
  const composer = box(composerNode);
  const usageOrbNode = first('.dream-usage-orb');
  const usageFillNode = usageOrbNode?.querySelector(':scope > .dream-usage-orb-fill') ?? null;
  const usageOrb = box(usageOrbNode);
  const surface = state?.adapter?.signals?.surface ?? (workHome ? 'work-home' : chatHome ? 'chat-home' :
    composerNode ? 'conversation' : 'utility');
  const composerExpected = surface !== 'utility' && !state?.adapter?.signals?.readOnly;
  const sidebarNode = first('.dream-sidebar');
  const sidebar = box(sidebarNode);
  const mainNode = first('.dream-main-surface');
  const main = box(mainNode);
  const hero = box(workHome ? first('.dream-hero-source', workHome) : null);
  const suggestionsNode = workHome ? first('.dream-suggestions', workHome) : null;
  const cards = suggestionsNode ? [...suggestionsNode.querySelectorAll('button')]
    .filter(visible).map(box) : [];
  // Current Codex releases no longer expose article/message-author markers on
  // Chat conversations. Detect rendered prose semantically and exclude native
  // chrome/editor regions instead of depending on generated Markdown classes.
  const messages = mainNode ? [...mainNode.querySelectorAll('p, li, pre, blockquote, h1, h2, h3')]
    .filter((node) => visible(node) && !composerNode?.contains(node) && !node.closest('header')) : [];
  const modeButtons = [...document.querySelectorAll('button')].filter((node) =>
    visible(node) && ['Chat', 'Work'].includes((node.innerText || '').trim()));
  const modeBoxes = modeButtons.map(box);
  // Sample through more than two observer delays: a single screenshot can
  // miss the old alternating composer/home geometry entirely.
  await new Promise((resolve) => setTimeout(resolve, 450));
  const sameBox = (left, right) => !left || !right ? left === right :
    ['x', 'y', 'width', 'height'].every((key) => Math.abs(left[key] - right[key]) <= 1);
  const layoutStable = sameBox(main, box(first('.dream-main-surface'))) &&
    sameBox(composer, box(first('.composer-surface-chrome, .dream-composer-surface'))) &&
    modeButtons.every((button, index) => sameBox(modeBoxes[index], box(button))) &&
    state?.adapter?.signals?.surface === surface;
  const measured = [hero, ...cards, composer, usageOrb].filter(Boolean);
  const usagePercent = Number(usageOrbNode?.dataset.dreamUsagePercent);
  const usageFillPercent = usageFillNode ?
    parseFloat(getComputedStyle(usageFillNode, '::before').height) /
      usageFillNode.getBoundingClientRect().height * 100 : NaN;
  const checks = {
    skinInstalled: document.documentElement.classList.contains('codex-dream-skin'),
    adapterConfident: Boolean(state?.adapter?.version) && state.adapter.confidence >= 0.65,
    layoutStable,
    mainFound: Boolean(main),
    sidebarFoundOrCollapsed: Boolean(sidebar) || innerWidth < 800,
    sidebarHit: !sidebar || sidebarNode.contains(document.elementFromPoint(
      sidebar.x + sidebar.width / 2, Math.min(sidebar.bottom - 12, sidebar.y + sidebar.height / 2))),
    homeModeToggleHit: modeButtons.every((button) => {
      const rect = button.getBoundingClientRect();
      return button.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2));
    }),
    usageOrb: !composerExpected || (Number.isFinite(usagePercent) &&
      usagePercent >= 0 && usagePercent <= 100 &&
      Boolean(usageFillNode) && Math.abs(usageFillPercent - usagePercent) <= 2 &&
      getComputedStyle(usageOrbNode, '::before').backgroundColor !== 'rgba(0, 0, 0, 0)' &&
      getComputedStyle(usageOrbNode).borderRadius === '50%' &&
      !usageOrbNode.hasAttribute('title') &&
      usageOrbNode.textContent.trim() === '' && /% remaining.*Resets/.test(usageOrbNode.dataset.tooltip || '') &&
      Boolean(usageOrb && composer && usageOrb.width === 22 && usageOrb.height === 22 &&
        Math.abs(usageOrb.x - (composer.x - 11)) <= 2 &&
        Math.abs(usageOrb.y - (composer.y - 11)) <= 2)),
    composerLocal: !composerExpected || (Boolean(composer) && composer.height < innerHeight * .45 &&
      composer.width * composer.height < innerWidth * innerHeight * .5),
    composerHit: !composerExpected || Boolean(composerNode && composer &&
      composerNode.contains(document.elementFromPoint(composer.x + composer.width / 2, composer.y + composer.height / 2))),
    noDocumentOverflow: document.documentElement.scrollWidth <= document.documentElement.clientWidth &&
      document.documentElement.scrollHeight <= document.documentElement.clientHeight,
    allMeasuredInViewport: measured.every((rect) => rect.x >= -1 && rect.y >= -1 &&
      rect.right <= innerWidth + 1 && rect.bottom <= innerHeight + 1),
    noHomeComposerOverlap: cards.every((card) => intersection(card, composer) === 0) &&
      intersection(hero, composer) === 0,
    surfaceComplete: surface === 'work-home' ? Boolean(hero) &&
      (!suggestionsNode || (cards.length >= 2 && cards.length <= 4)) :
      surface === 'chat-home' ? Boolean(chatFrame) && getComputedStyle(chatFrame, '::before').backgroundImage !== 'none' : true,
    homeModeToggleInCanvas: surface !== 'chat-home' || modeButtons.every((button) => {
      const rect = button.getBoundingClientRect();
      const frame = chatFrame?.getBoundingClientRect();
      return frame && chatFrame.contains(button) && rect.left >= frame.left + 16 &&
        rect.right <= frame.right - 16 && rect.top >= frame.top + 8 && rect.bottom <= frame.bottom - 16;
    }),
    fullscreenCanvasAtTop: surface !== 'work-home' || state?.layout !== 'fullscreen' ||
      (mainNode.classList.contains('dream-work-home-frame') &&
        parseFloat(getComputedStyle(mainNode, '::before').top) === 8 &&
        getComputedStyle(mainNode, '::before').backgroundImage !== 'none'),
    conversationContentVisible: surface !== 'conversation' || messages.length > 0,
    utilityHasNoConversationArt: surface !== 'utility' ||
      !mainNode.classList.contains('dream-conversation-shell'),
  };
  return {
    surface,
    theme: state?.theme ?? null,
    layout: state?.layout ?? null,
    adapter: state?.adapter ?? null,
    viewport: { width: innerWidth, height: innerHeight },
    geometry: { main, sidebar, hero, cards, composer, usageOrb, visibleMessages: messages.length },
    usagePercent: Number.isFinite(usagePercent) ? usagePercent : null,
    checks,
    pass: Object.values(checks).every(Boolean),
  };
})()`;

const options = parseArgs(process.argv.slice(2));
const session = await new Session(await findTarget(options.port)).open();
const original = await session.evaluate(`({
  layout: window.__CODEX_DREAM_SKIN_STATE__?.layout,
  width: innerWidth,
  height: innerHeight,
})`);
const results = [];
try {
  for (const layout of ["fullscreen", "banner"]) {
    // Reset responsive UI state between layout groups before narrowing again.
    await session.send("Emulation.clearDeviceMetricsOverride");
    await new Promise((resolve) => setTimeout(resolve, 700));
    for (const [width, height] of options.sizes) {
      await session.send("Emulation.setDeviceMetricsOverride", {
        width, height, deviceScaleFactor: 1, mobile: false,
      });
      await session.evaluate(`(() => {
        const state = window.__CODEX_DREAM_SKIN_STATE__;
        // Persist only for the duration of the audit so a concurrently running
        // AutoSkin watcher cannot re-inject the user's stored layout mid-matrix.
        state.setLayout(${JSON.stringify(layout)}, true);
        state.ensure();
        return true;
      })()`);
      await new Promise((resolve) => setTimeout(resolve, 700));
      results.push(await session.evaluate(auditExpression));
    }
  }
} finally {
  await session.send("Emulation.clearDeviceMetricsOverride");
  if (original.layout) {
    await session.evaluate(`(() => {
      const state = window.__CODEX_DREAM_SKIN_STATE__;
      localStorage.setItem('codex-dream-skin.layout', ${JSON.stringify(original.layout)});
      state?.setLayout(${JSON.stringify(original.layout)}, true);
      state?.ensure();
      return true;
    })()`);
  }
  session.close();
}

const report = {
  port: options.port,
  surface: results[0]?.surface ?? null,
  scenarios: results.length,
  passed: results.filter((item) => item.pass).length,
  failed: results.filter((item) => !item.pass).length,
  results,
};
console.log(JSON.stringify(report, null, 2));
if (report.failed) process.exitCode = 2;
