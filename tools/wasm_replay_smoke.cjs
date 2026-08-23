#!/usr/bin/env node
'use strict';
// Headless smoke for the EXACT wasm module the static bundle ships. wasm32
// failures (integer overflow traps, address-space exhaustion, a stale export
// list) are invisible to the native 64-bit tests, so CI runs the emitted
// module under node against a recorded replay.
//
//   node tools/wasm_replay_smoke.cjs <path/to/raid_replay.js> <replay.json> [expectedTicks]

const fs = require('fs');
const path = require('path');

const modulePath = process.argv[2];
const replayPath = process.argv[3];
const expectedTicks = process.argv[4] ? Number(process.argv[4]) : 0;

if (!modulePath || !replayPath) {
  console.error('usage: wasm_replay_smoke.cjs <raid_replay.js> <replay.json> [ticks]');
  process.exit(2);
}

function fail(message) {
  console.error('WASM-SMOKE FAIL: ' + message);
  process.exit(1);
}

const Module = {
  locateFile: function (file) { return path.join(path.dirname(modulePath), file); },
  onAbort: function (what) { fail('runtime aborted: ' + what); }
};
global.Module = Module;

Module.onRuntimeInitialized = function () {
  const decode = (ptr, len) => !ptr || !len ? '' :
    new TextDecoder().decode(Module.HEAPU8.slice(ptr, ptr + len));

  const bytes = new Uint8Array(fs.readFileSync(replayPath));
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const ok = Module._raid_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (!ok) fail('rejected a good replay: ' + decode(Module._raid_error_ptr(), Module._raid_error_len()));

  const ticks = Module._raid_tick_count();
  if (ticks <= 0) fail('re-derived zero ticks');
  if (expectedTicks && ticks !== expectedTicks) {
    fail('tick total ' + ticks + ' != recorded ' + expectedTicks);
  }
  if (Module._raid_mismatch_tick() !== -1) {
    fail('digest mismatch at tick ' + Module._raid_mismatch_tick());
  }

  const meta = JSON.parse(decode(Module._raid_meta_ptr(), Module._raid_meta_len()));
  if (meta.protocol !== 'raid.replay.v1') fail('bad protocol in meta');
  if (!meta.results || !meta.results.scores) fail('meta carries no results');

  const frameAt = (t) => {
    const got = Module._raid_frame(t);
    if (got < 0) fail('frame ' + t + ' failed: ' + decode(Module._raid_error_ptr(), Module._raid_error_len()));
    return JSON.parse(decode(Module._raid_frame_ptr(), Module._raid_frame_len()));
  };

  // Advance to the end one frame at a time, then prove seeking lands exactly.
  let last = null;
  for (let t = 0; t < ticks; t++) last = frameAt(t);
  if (last.t !== ticks - 1) fail('advancing to the end landed on ' + last.t);
  const endDigest = last.d;

  const mid = Math.floor(ticks / 2);
  const seekMid = frameAt(mid);
  if (seekMid.t !== mid) fail('seek-to-mid landed on ' + seekMid.t);
  const seekEnd = frameAt(ticks - 1);
  if (seekEnd.t !== ticks - 1) fail('seek-to-end landed on ' + seekEnd.t);
  if (seekEnd.d !== endDigest) fail('seek-to-end digest differs from playback');
  const again = frameAt(mid);
  if (again.d !== seekMid.d) fail('re-seeking mid gave a different digest');

  // Malformed inputs are rejected with a message rather than a crash.
  const reject = (label, payload) => {
    const raw = Buffer.from(payload);
    const ptr = Module._malloc(raw.length || 1);
    Module.HEAPU8.set(raw, ptr);
    const accepted = Module._raid_load_replay(ptr, raw.length);
    Module._free(ptr);
    if (accepted) fail('accepted a malformed replay: ' + label);
    const message = decode(Module._raid_error_ptr(), Module._raid_error_len());
    if (!message) fail('rejected ' + label + ' with no message');
  };
  const good = JSON.parse(fs.readFileSync(replayPath, 'utf8'));
  reject('truncated JSON', fs.readFileSync(replayPath, 'utf8').slice(0, 400));
  reject('bad protocol', JSON.stringify(Object.assign({}, good, { protocol: 'nope.v1' })));
  reject('missing map', JSON.stringify(Object.assign({}, good, { map: null })));
  reject('empty', '');

  console.log('WASM-SMOKE OK: ' + ticks + ' ticks, digest ' + endDigest +
    ', ' + (meta.events ? meta.events.length : 0) + ' events');
  process.exit(0);
};

require(path.resolve(modulePath));
