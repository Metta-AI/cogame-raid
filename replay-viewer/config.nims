import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup): with Nim's own allocator a bad free silently poisons the
# freelists, dlmalloc traps loudly instead.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped bundle owns the wasm runtime
# in a Dedicated Worker, and node so CI can smoke-run the EXACT emitted module
# (tools/wasm_replay_smoke.cjs) - wasm32-only failures (integer overflow traps,
# address-space exhaustion) are invisible to the native 64-bit tests.
# ABORTING_MALLOC matters: with -d:useMalloc Nim never checks malloc for nil
# and wasm32 has no memory protection, so a failed allocation would otherwise
# write a seq header through the nil pointer into address 0.
switch(
  "passL",
  (&"""
  -o {distDir / "raid_replay.js"}
  --preload-file {rootDir / "data"}@data
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_raid_load_replay,_raid_frame,_raid_tick_count,_raid_mismatch_tick,_raid_meta_ptr,_raid_meta_len,_raid_frame_ptr,_raid_frame_len,_raid_error_ptr,_raid_error_len
  """).replace("\n", " ")
)
