## Raid static replay viewer, wasm side.
##
## JS hands the raw replay bytes to `raid_load_replay`; this module parses
## them and re-derives the whole encounter with the SAME Nim sim the game
## server runs, from `seed` + `map` + `config` + the recorded orders, then
## exposes one compact frame per tick for the renderer to draw and the
## keyframe digests it re-derived so the page can prove the re-derivation
## matched (`raid_mismatch_tick`).

import std/[json]
import raid/[types, state, sim, replay]

var
  meta: string
  frame: string
  lastError: string
  frames: seq[Keyframe]
  events: JsonNode
  mismatch: int = -1

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc frameJson(index: int): JsonNode =
  let f = frames[index]
  var cogs = newJArray()
  for row in f.cogs:
    cogs.add(%row)
  var adds = newJArray()
  for row in f.adds:
    adds.add(%row)
  var pools = newJArray()
  for row in f.pools:
    pools.add(%row)
  var tel = newJArray()
  for row in f.tel:
    tel.add(%row)
  var meters = newJArray()
  for row in f.meters:
    meters.add(%row)
  %*{
    "t": f.t, "d": int(f.digest), "cogs": cogs, "boss": f.boss,
    "adds": adds, "pools": pools, "tel": tel, "mtr": meters
  }

proc raidLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "raid_load_replay", cdecl.} =
  try:
    lastError = ""
    mismatch = -1
    let payload = parseJson(bytesFromPointer(data, int(length)))
    let rebuilt = rederive(payload, keyframeEvery = 1)
    frames = rebuilt.keyframes
    mismatch = firstDigestMismatch(payload, rebuilt)
    events = payload{"events"}
    if events == nil:
      events = newJArray()
    meta = $ %*{
      "protocol": payload{"protocol"},
      "game_version": payload{"game_version"},
      "seed": payload{"seed"},
      "config": payload{"config"},
      "map": payload{"map"},
      "names": payload{"names"},
      "ticks_per_second": TargetFps,
      "turn_ticks": payload{"turn_ticks"},
      "tick_count": frames.len,
      "phases": payload{"phases"},
      "events": events,
      "results": payload{"results"},
      "mismatch_tick": mismatch
    }
    if frames.len == 0:
      raise newException(RaidError, "replay re-derived zero frames")
    frame = $frameJson(0)
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc raidFrame(index: cint): cint {.exportc: "raid_frame", cdecl.} =
  try:
    if frames.len == 0:
      lastError = "no replay loaded"
      return -1
    let clamped = clamp(int(index), 0, frames.len - 1)
    frame = $frameJson(clamped)
    return cint(clamped)
  except CatchableError as error:
    lastError = error.msg
    return -1

proc raidTickCount(): cint {.exportc: "raid_tick_count", cdecl.} =
  cint(frames.len)

proc raidMismatchTick(): cint {.exportc: "raid_mismatch_tick", cdecl.} =
  cint(mismatch)

proc raidMetaPointer(): ptr uint8 {.exportc: "raid_meta_ptr", cdecl.} =
  if meta.len == 0: nil else: cast[ptr uint8](meta[0].addr)

proc raidMetaLength(): cint {.exportc: "raid_meta_len", cdecl.} =
  cint(meta.len)

proc raidFramePointer(): ptr uint8 {.exportc: "raid_frame_ptr", cdecl.} =
  if frame.len == 0: nil else: cast[ptr uint8](frame[0].addr)

proc raidFrameLength(): cint {.exportc: "raid_frame_len", cdecl.} =
  cint(frame.len)

proc raidErrorPointer(): ptr uint8 {.exportc: "raid_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc raidErrorLength(): cint {.exportc: "raid_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `meta` and `frame` while JS keeps calling into the module.
  ## Exiting with a live runtime skips the epilogue so the globals stay valid.
  emscriptenExitWithLiveRuntime()
