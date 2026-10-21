'use strict';
// Execute actual viewer JS. The module/DOM model follows the inspected Nim
// close contract; this is not a real browser, WASM, GL or BFCache admission test.
const fs = require('fs'), path = require('path'), assert = require('assert');
const vm = require('vm'), crypto = require('crypto');
const root = path.resolve(__dirname, '..');
const sourcePath = process.argv[2] || path.join(root, 'replay-viewer/polyworld/replay.js');
const source = fs.readFileSync(sourcePath, 'utf8');
const entryPath = path.join(root, 'replay-viewer/polyworld/raid_polyworld.nim');
const entry = fs.readFileSync(entryPath, 'utf8');
const close = entry.split('proc raidClose()')[1].split('proc keepAlive()')[0];
assert(close.includes('renderer.closeShapeRenderer()'));
assert(close.includes('initialized = false'));
assert(close.includes('runtime = PresentationReplay()'));
assert(close.includes('payload = ""'));
const oraclePath = process.env.RAID_LIFECYCLE_ORACLE;
const oracle = oraclePath ? JSON.parse(fs.readFileSync(oraclePath, 'utf8')) : {
  summary: {terminal_tick: 3616, end_rule: 'wipe', score: 0},
  frames: Array.from({length: 3616}, (_, index) =>
    ({index, digest: index, scene: {tick: index + 1, phase: 1}}))
};
assert(oracle.frames.length > 3303);

async function loadViewer() {
  let active = false, initialized = false, payloadLength = 0;
  let closeCalls = 0, rendererCloses = 0, loads = 0, now = 0, animation;
  const heap = new Uint8Array(1024 * 1024);
  const payload = value => {
    const bytes = new TextEncoder().encode(JSON.stringify(value));
    heap.set(bytes); payloadLength = bytes.length;
  };
  const module = {
    HEAPU8: heap, _malloc: () => 0, _free: () => {},
    _raid_pw_load: () => {
      active = initialized = true; loads++; payload(oracle.summary);
      return oracle.frames.length;
    },
    _raid_pw_ptr: () => 0, _raid_pw_len: () => payloadLength,
    _raid_pw_error: () => 0, UTF8ToString: () => 'frame index out of bounds',
    _raid_pw_inspect: index => {
      if (!active || index < 0 || index >= oracle.frames.length) return -1;
      payload(oracle.frames[index]); return index;
    },
    _raid_pw_draw: index => module._raid_pw_inspect(index),
    _raid_pw_close: () => {
      if (initialized) {rendererCloses++; initialized = false;}
      active = false; payloadLength = 0; closeCalls++;
    }
  };
  const listeners = new Map(), elements = {};
  const window = {addEventListener: (name, fn, options) => {
    const list = listeners.get(name) || [];
    list.push({fn, once: Boolean(options?.once)}); listeners.set(name, list);
  }};
  for (const name of ['canvas', 'seek', 'play', 'status', 'tick', 'restart', 'back', 'forward'])
    elements[name] = {value: '0', textContent: '', disabled: name === 'play'};
  let size = {width: 1235, height: 659};
  elements.canvas.getBoundingClientRect = () => size;
  const document = {getElementById: name => elements[name], documentElement: {dataset: {}}};
  const context = {window, document, RaidPolyworldModule: async () => module,
    fetch: async () => ({ok: true, arrayBuffer: async () => new ArrayBuffer(2)}),
    AbortSignal, Uint8Array, TextDecoder, Math, JSON, Error, String, Number,
    devicePixelRatio: 1, performance: {now: () => now},
    requestAnimationFrame: fn => {animation = fn;}};
  await vm.runInNewContext(source, context, {filename: sourcePath, timeout: 1000});
  const dispatch = (name, event) => {
    const list = listeners.get(name) || [];
    for (const listener of list) listener.fn(event);
    listeners.set(name, list.filter(listener => !listener.once));
  };
  assert.strictEqual(document.documentElement.dataset.replayLoaded, 'true');
  assert.strictEqual(elements.play.disabled, false);
  return {api: window.raidReplay, elements, dispatch,
    state: () => ({active, initialized, payloadLength, closeCalls, rendererCloses, loads}),
    resize: () => {size = {width: 340, height: 181}; dispatch('resize', {});},
    advance: milliseconds => {now += milliseconds; animation(now);}};
}

(async () => {
  const viewer = await loadViewer(), api = viewer.api;
  const expected = index => oracle.frames[index];
  const restored = [];
  for (const index of [3279, 0, 3615]) {
    assert.deepStrictEqual(api.seek(index), expected(index));
    if (index !== 3615) api.start();
    viewer.dispatch('pagehide', {persisted: true});
    assert.strictEqual(viewer.state().closeCalls, 0, 'persisted pagehide must preserve runtime');
    assert.strictEqual(api.playing, false, 'navigation pauses playback');
    assert.strictEqual(viewer.elements.play.textContent, 'Play');
    viewer.advance(60000);
    viewer.dispatch('pageshow', {persisted: true});
    assert.strictEqual(viewer.api, api);
    assert.deepStrictEqual(api.seek(index), expected(index), 'restored seek remains valid');
    assert.strictEqual(viewer.state().loads, 1, 'restoration needs no reload');
    restored.push({index, digest: expected(index).digest});
  }
  api.seek(3279); viewer.resize();
  assert.deepStrictEqual(api.inspect(3279), expected(3279));
  assert.strictEqual(viewer.elements.canvas.width, 340);
  api.start(); viewer.advance(100);
  assert.strictEqual(api.index, 3281, 'play clock restarts without navigation time debt');
  viewer.elements.back.onclick(); viewer.elements.forward.onclick();
  assert.strictEqual(api.index, 3281);
  viewer.elements.seek.value = '3279'; viewer.elements.seek.oninput();
  assert.strictEqual(api.index, 3279);
  viewer.dispatch('pagehide', {persisted: false});
  assert.deepStrictEqual(viewer.state(), {active: false, initialized: false,
    payloadLength: 0, closeCalls: 1, rendererCloses: 1, loads: 1});
  assert.throws(() => api.inspect(3279), /frame index out of bounds/);
  const direct = await loadViewer(); direct.api.start();
  direct.dispatch('pagehide', {persisted: false});
  assert.strictEqual(direct.api.playing, false);
  assert.deepStrictEqual(direct.state(), {active: false, initialized: false,
    payloadLength: 0, closeCalls: 1, rendererCloses: 1, loads: 1});
  const sha = text => crypto.createHash('sha256').update(text).digest('hex');
  console.log(JSON.stringify({state: 'pass', source: sourcePath, source_sha256: sha(source),
    native_close_source_sha256: sha(entry), restored,
    final_after_restores: viewer.state(), direct_final: direct.state(),
    clock_resize_transport: 'pass', oracle: oraclePath || 'synthetic lifecycle unit data',
    limitations: 'Actual JS in CPU VM; source-bound module/DOM model. No browser BFCache admission, WASM execution or GL resource proof.'}));
})().catch(error => {console.error(error.stack || error); process.exitCode = 1;});
