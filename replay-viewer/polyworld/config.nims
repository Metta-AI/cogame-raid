import std/os
let root = currentSourcePath().parentDir.parentDir.parentDir
let output = getEnv("RAID_BROWSER_OUTPUT")
doAssert output.len > 0, "RAID_BROWSER_OUTPUT must name a private bundle directory"
switch("path", root / "src")
switch("threads", "off")
switch("parallelBuild", "1")
switch("nimcache", output / "nimcache")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:emscripten
--define:release
--define:useMalloc
--define:noSignalHandler
switch("passL", "-o " & output / "raid_polyworld.js" &
  " --preload-file " & root / "data" & "@data -O2 -sALLOW_MEMORY_GROWTH" &
  " -sABORTING_MALLOC=1 -sENVIRONMENT=web -sMODULARIZE=1" &
  " -sEXPORT_NAME=RaidPolyworldModule -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2" &
  " -sEXPORTED_RUNTIME_METHODS=HEAPU8,UTF8ToString" &
  " -sEXPORTED_FUNCTIONS=_main,_malloc,_free,_raid_pw_load,_raid_pw_inspect,_raid_pw_draw,_raid_pw_ptr,_raid_pw_len,_raid_pw_error,_raid_pw_close")
