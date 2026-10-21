## Optional experiment, not part of the hosted game or default test glob.
## Compile with --path:tests --path:<pinned-polyworld>/src and run under Xvfb
## with LIBGL_ALWAYS_SOFTWARE=1. Argument: private evidence output directory.
import std/[json, os, strutils, tables]
import support/helpers
import raid/[broadcast, polyworld_presentation]
import chroma, opengl, pixie, vmath, windy
import polyworld/shapes

const Scale = 0.01'f32

proc point(x, y: float32): Vec3 = vec3(x * Scale, 0, y * Scale)

proc addShape(renderer: var ShapeRenderer, shape: HazardShape, color: ColorRGBX) =
  for span in shape.spans:
    let a = span.first.float32 - 0.5'f32
    let b = span.last.float32 + 0.5'f32
    let y = span.y.float32
    renderer.addQuad(point(a, y - 0.5), point(b, y - 0.5),
      point(b, y + 0.5), point(a, y + 0.5), color)

proc paint(renderer: var ShapeRenderer, scene: RaidScene) =
  renderer.clear()
  renderer.addCircle(point(PitCx.float32, PitCy.float32),
    PitRadius.float32 * Scale, rgbx(30, 38, 46, 254), sides = 256)
  for shape in scene.hazards:
    renderer.addShape(shape,
      if shape.soakNeeded > 0: rgbx(50, 220, 140, 190)
      else: rgbx(245, 110, 40, 190))
  # Interrupt is an exact digital range boundary, not a new action mask.
  for marker in scene.interrupts:
    let disk = HazardShape(kind: skDisk, cx: marker.cx, cy: marker.cy,
      radius: marker.radius)
    for span in disk.spans:
      for x in [span.first, span.last]:
        renderer.addSquare(point(x.float32, span.y.float32), Scale,
          rgbx(80, 190, 240, 90))
  for body in @[scene.boss] & scene.players:
    if body.alive:
      renderer.addSquare(point(body.x.float32, body.y.float32),
        body.halfSize.float32 * 2 * Scale,
        if body.slot < 0: rgbx(230, 55, 65, 254)
        elif body.slot == 0: rgbx(70, 130, 245, 254)
        elif body.slot == 1: rgbx(50, 215, 110, 254)
        else: rgbx(245, 205, 75, 254))

proc capture(renderer: var ShapeRenderer, scene: RaidScene, path: string) =
  glViewport(0, 0, MapWidth.GLsizei, MapHeight.GLsizei)
  glClearColor(0.03, 0.04, 0.05, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderer.paint(scene)
  var projection: Mat4
  # Vmath matrices are noinit: initialize every element before uploading.
  for column in 0 .. 3:
    for row in 0 .. 3: projection[column, row] = 0
  projection[0, 0] = 2 / (MapWidth.float32 * Scale)
  projection[2, 1] = -2 / (MapHeight.float32 * Scale)
  projection[1, 2] = -0.01
  projection[3, 0] = -1 + 1 / MapWidth.float32
  projection[3, 1] = 1 - 1 / MapHeight.float32
  projection[3, 3] = 1
  renderer.draw(projection)
  var program: GLint
  glGetIntegerv(GL_CURRENT_PROGRAM, program.addr)
  let location = glGetUniformLocation(program.GLuint, "shapeViewProjection")
  check(location >= 0, "Polyworld projection uniform is live")
  var uploaded: array[16, float32]
  glGetUniformfv(program.GLuint, location, uploaded[0].addr)
  for column in 0 .. 3:
    for row in 0 .. 3:
      checkEq(uploaded[column * 4 + row], projection[column, row],
        "the actual GL projection matches the initialized matrix")
  glFinish()
  check(glGetError() == GL_NO_ERROR, "actual Polyworld GL draw succeeds")
  var pixels = newSeq[uint8](MapWidth * MapHeight * 4)
  glReadPixels(0, 0, MapWidth.GLsizei, MapHeight.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)
  let image = newImage(MapWidth, MapHeight)
  var nonBackground = 0
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let i = ((MapHeight - 1 - y) * MapWidth + x) * 4
      image[x, y] = rgbx(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
      if pixels[i] > 15 or pixels[i + 1] > 15: nonBackground.inc
  image.writeFile(path)
  echo "FRAMEBUFFER: ", path, " colored pixels=", nonBackground,
    " read error=", glGetError().uint32
  check(nonBackground > 10000, "framebuffer contains a real rendered arena")

proc main() =
  checkEq(paramCount(), 1, "private output directory is required")
  let outDir = paramStr(1)
  createDir(outDir)
  var reference = newWorld(testConfig())
  for slot in 0 ..< Seats: reference.names[slot] = "PRIVATE-POLICY-" & $slot
  let kinds = @[skStalwart, skStalwart, skStalwart, skStalwart, skStalwart]
  let decide: Decider = proc(view: Sim, seats: seq[int]): seq[Decision] =
    result = scriptedDecisions(view, seats, kinds)
    for i, seat in seats: result[i].order.note = "PRIVATE-NOTE-" & $seat
  let clock: Clock = proc(): float = 0.0
  runEncounter(reference, decide, clock, kinds, nil)
  let replay = replayJson(reference, resultsJson(reference))
  writeFile(outDir / "encounter.json", $replay)
  checkEq(reference.boss.phase, 3, "retained encounter reaches all three phases")
  var world = newWorld(reference.config)
  world.names = reference.names
  world.policyKinds = reference.policyKinds
  world.keyframeEvery = 1
  world.encounterStart()
  let orders = ordersFromEvents(replay, Seats)
  let sources = newSeq[OrderSource](Seats)
  let latencies = newSeq[int](Seats)
  let window = newWindow("Raid Polyworld feasibility", ivec2(MapWidth, MapHeight),
    openglVersion = OpenGL4Dot1)
  window.makeContextCurrent()
  loadExtensions()
  pollEvents()
  echo "GL_RENDERER: ", cast[cstring](glGetString(GL_RENDERER))
  var renderer = initShapeRenderer()
  defer: renderer.closeShapeRenderer()
  var seen = initTable[string, bool]()
  var first = initTable[int, int]()
  var last = initTable[int, int]()
  var views = 0
  var captures = 0
  var nativeFrames = open(outDir / "native-frames.jsonl", fmWrite)
  defer: nativeFrames.close()
  while not world.done:
    let t = world.tick
    if world.turnBoundary():
      let turn = t div world.config.turnTicks
      if orders.hasKey(turn): world.installOrders(orders[turn], sources, latencies)
      for slot in 0 ..< Seats:
        let payload = $seatView(world, slot)
        let parsed = parseJson(payload)
        check(not parsed.hasKey("seed") and not parsed.hasKey("config"), "no seeded config")
        check("PRIVATE-POLICY-" notin payload and "PLAYER_PROMPT" notin payload,
          "real serialized seat payload has no policy identity or prompt")
        for other in 0 ..< Seats:
          if other != slot:
            check("PRIVATE-NOTE-" & $other notin payload, "no other seat note")
        if t == 0: writeFile(outDir / ("seat-" & $slot & ".json"), payload)
        views.inc
    world.stepOnce()
    let digest = world.raidStateDigest()
    let scene = projectScene(world)
    checkEq(world.raidStateDigest(), digest, "projection preserves state")
    checkEq(scene.hazards.len, world.telegraphs.len, "no stale or missing hazard")
    for i, shape in scene.hazards:
      checkEq(shape.fuse, world.telegraphs[i].fuse, "exact fuse")
      if not first.hasKey(shape.id): first[shape.id] = t
      last[shape.id] = t
    let frame = world.keyframes[^1]
    nativeFrames.writeLine($ %*{"t": frame.t, "d": int64(frame.digest),
      "cogs": frame.cogs, "boss": frame.boss, "adds": frame.adds,
      "pools": frame.pools, "tel": frame.tel, "mtr": frame.meters})
    var labels = @["phase-" & $scene.phase]
    for tel in world.telegraphs: labels.add($tel.kind)
    if scene.interrupts.len > 0: labels.add("interrupt")
    for label in labels:
      if not seen.hasKey(label):
        renderer.capture(scene, outDir / (label & "-" & $t & ".png"))
        seen[label] = true
        captures.inc
  checkEq(firstDigestMismatch(replay, world), -1, "every retained checkpoint")
  check(controlsMatch(replay, world), "every retained control byte")
  checkEq($resultsJson(world), $resultsJson(reference), "damage, score, terminal tick")
  var lifetimes = newJArray()
  for event in replay["events"]:
    if event["type"].getStr() == "telegraph":
      let id = event["id"].getInt()
      let onset = event["t"].getInt()
      let fuse = event["fuse_ticks"].getInt()
      checkEq(first[id], onset, "exact onset tick")
      # A terminal episode can legitimately cut off a still-live telegraph.
      let expectedLast = min(onset + fuse - 1, world.tick - 1)
      checkEq(last[id], expectedLast, "exact expiry or terminal cutoff")
      lifetimes.add(%*{"id": id, "kind": event["kind"], "onset": onset,
        "last_visible": last[id], "resolution_step": onset + fuse,
        "terminal_cutoff": onset + fuse >= world.tick})
  writeFile(outDir / "native-proof.json", $ %*{"ticks": world.tick,
    "checkpoints": replay["keyframes"].len, "views_checked": views,
    "captures": captures, "telegraphs": lifetimes, "results": resultsJson(world),
    "digest_mismatch": -1, "controls_match": true})
  echo "RAID-POLYWORLD OK: ", world.tick, " ticks, ", views,
    " private payloads, ", lifetimes.len, " telegraphs, ", captures, " GL captures"

when isMainModule:
  main()
