## Real WebGL2 presentation, with Raid's own replay/simulation and adapter.
import std/json
import raid/[types, polyworld_replay, polyworld_draw]
import polyworld/shapes
import windy/platforms/emscripten/emdefs

var
  runtime: PresentationReplay
  renderer: ShapeRenderer
  initialized = false
  payload: string
  lastError: string

proc raidLoad(data: ptr uint8, length: cint): cint {.exportc: "raid_pw_load", cdecl.} =
  try:
    if length <= 0: raise newException(RaidError, "empty replay")
    var bytes = newString(length.int)
    copyMem(bytes[0].addr, data, length.int)
    runtime = loadPresentationReplay(parseJson(bytes))
    if not initialized:
      var attributes: EmscriptenWebGLContextAttributes
      emscripten_webgl_init_context_attributes(attributes.addr)
      attributes.majorVersion = 2
      attributes.antialias = false
      attributes.preserveDrawingBuffer = true
      let context = emscripten_webgl_create_context("#canvas", attributes.addr)
      if context <= 0 or emscripten_webgl_make_context_current(context) != 0:
        raise newException(RaidError, "WebGL2 context unavailable")
      renderer = initShapeRenderer()
      initialized = true
    payload = $runtime.summary
    return runtime.scenes.len.cint
  except Exception as error:
    lastError = $error.name & ": " & error.msg
    return -1

proc raidFrame(index: cint): cint {.exportc: "raid_pw_inspect", cdecl.} =
  try:
    payload = $runtime.frameJson(index.int)
    return index
  except Exception as error:
    lastError = error.msg
    return -1

proc raidDraw(index, width, height: cint): cint {.exportc: "raid_pw_draw", cdecl.} =
  try:
    if raidFrame(index) < 0: return -1
    if not initialized or width <= 0 or height <= 0:
      raise newException(RaidError, "invalid drawing context or viewport")
    renderer.drawScene(runtime.scenes[index.int], width.int, height.int)
    return index
  except Exception as error:
    lastError = error.msg
    return -1

proc raidPointer(): cstring {.exportc: "raid_pw_ptr", cdecl.} = payload.cstring
proc raidLength(): cint {.exportc: "raid_pw_len", cdecl.} = payload.len.cint
proc raidError(): cstring {.exportc: "raid_pw_error", cdecl.} = lastError.cstring
proc raidClose() {.exportc: "raid_pw_close", cdecl.} =
  if initialized:
    renderer.closeShapeRenderer()
    initialized = false
  runtime = PresentationReplay()
  payload = ""

proc keepAlive() {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}
keepAlive()
