'use strict';
// The replay Worker: owns the wasm runtime and the OffscreenCanvas, so the
// page thread never blocks on re-deriving 6480 ticks of integer physics.
//
// broadcast_core.js is shared with the page shell and publishes through
// `window`; a classic Worker can provide that alias without a second bundle.
self.window = self;

var Module = null;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;
var tickCount = 0;
var cursor = 0;
var art = {};

var ART_FILES = {
  floor: 'art/floor_foundry.jpg',
  boss: 'art/boss_smelter.png',
  add: 'art/add_crawler.png',
  cogTank: 'art/cog_tank.png',
  cogHealer: 'art/cog_healer.png',
  cogDps: 'art/cog_dps.png',
  pool: 'art/pool.png',
  ring: 'art/telegraph_ring.png',
  pillar: 'art/pillar.png'
};

function decodeString(pointer, length) {
  if (!pointer || !length) return '';
  return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
}

function runtimeError() {
  var text = decodeString(Module._raid_error_ptr(), Module._raid_error_len());
  return text || 'Replay runtime rejected the replay';
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error)
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function frameAt(tick) {
  var got = Module._raid_frame(tick);
  if (got < 0) throw new Error(runtimeError());
  return JSON.parse(decodeString(Module._raid_frame_ptr(), Module._raid_frame_len()));
}

async function loadArt(base) {
  var names = Object.keys(ART_FILES);
  await Promise.all(names.map(async function (name) {
    try {
      var response = await fetch(new URL(ART_FILES[name], base).toString());
      if (!response.ok) return;
      art[name] = await createImageBitmap(await response.blob());
    } catch (ignored) {
      // Art is real but not load-bearing: the board falls back to flat
      // shapes rather than showing nothing at all.
    }
  }));
}

// MODULARIZE: the emitted script publishes a factory, so the runtime is
// created explicitly rather than by patching a global before it loads.
var modulePromise = null;
function ensureRuntime() {
  if (modulePromise) return modulePromise;
  modulePromise = self.RaidReplayModule({
    locateFile: function (file) {
      return new URL(file, self.location.href).toString();
    },
    onAbort: function (what) {
      reportFailure(new Error('Replay runtime aborted (' + what + ')'));
    }
  }).then(function (instance) {
    Module = instance;
    return instance;
  });
  return modulePromise;
}

async function start() {
  if (!initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    await ensureRuntime();
    core = self.RaidBroadcastCore.create({
      canvas: message.canvas,
      viewportWidth: message.width,
      viewportHeight: message.height,
      devicePixelRatio: message.dpr,
      art: art,
      onFirstFrame: function () { postMessage({ type: 'firstFrame' }); },
      onTransform: function (t) { postMessage({ type: 'transform', transform: t }); }
    });
    if (minimapSurface) core.attachMinimap(minimapSurface);
    core.setViewportSize(message.width, message.height, message.dpr);
    await loadArt(self.location.href);
    var response = await fetch(message.replayUrl, { credentials: 'omit', mode: 'cors' });
    if (!response.ok) throw new Error('Replay request returned HTTP ' + response.status);
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var ok = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._raid_load_replay(pointer, length);
    });
    if (!ok) throw new Error(runtimeError());
    runtimeLoaded = true;
    tickCount = Module._raid_tick_count();
    var meta = JSON.parse(decodeString(Module._raid_meta_ptr(), Module._raid_meta_len()));
    core.setMeta(meta);
    postMessage({ type: 'meta', meta: meta });
    cursor = 0;
    var first = frameAt(0);
    core.ingest(first);
    postMessage({
      type: 'loaded', tickCount: tickCount,
      mismatchTick: Module._raid_mismatch_tick(), frame: first
    });
  } catch (error) {
    reportFailure(error);
  }
}

function show(tick) {
  cursor = Math.max(0, Math.min(tickCount - 1, tick));
  var payload = frameAt(cursor);
  core.ingest(payload);
  return payload;
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(64, Number(frames) || 1));
    var payload = show(cursor + count);
    postMessage({
      type: 'advanced', tick: cursor, frame: payload,
      atEnd: cursor >= tickCount - 1,
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'seek' && runtimeLoaded) {
      var payload = show(Number(message.tick) || 0);
      postMessage({ type: 'advanced', tick: cursor, frame: payload,
        atEnd: cursor >= tickCount - 1,
        draws: core ? core.getPaceStats().draws : 0 });
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'view' && core) {
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './raid_replay.js');
