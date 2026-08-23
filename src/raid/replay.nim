## The replay: strict UTF-8 JSON, protocol `raid.replay.v1`, self-sufficient.
##
## Paintbot writes a binary `COWLDCTF` file; raid writes JSON because SPEC's
## definition of done fetches the replay from S3 and requires valid UTF-8 JSON
## with a matching `protocol` and a legal `results.reason`, and the shared
## `tools/ci/docker_smoke.sh` defaults to `SMOKE_REQUIRE_REPLAY_JSON=1`. The
## bulk payload - the per-tick control bytes - rides as one base64 string, so
## the file stays small and the document stays parseable.
##
## Everything the viewer needs is in these bytes: names, colours, config, map
## geometry, the phase table, per-tick controls, per-second states with their
## digests, the event transcript, the seed and the results. The viewer
## contacts nothing but the S3 URL it was given.

import std/[base64, json, tables]
import types, config, arena, state, events, sim, scoring, labels

const
  ReplayProtocol* = "raid.replay.v1"
  ReplayFormatVersion* = 1
  ControlBytesPerCog* = 4

proc roleColors*(): JsonNode =
  %*{
    "tank": "#4b7bec", "healer": "#2ecc71",
    "dps": ["#f2c14e", "#e8743b", "#a55eea"],
    "boss": "#d63031", "add": "#8d6e63"
  }

proc keyframesJson(sim: Sim): JsonNode =
  result = newJArray()
  for frame in sim.keyframes:
    var cogs = newJArray()
    for row in frame.cogs:
      cogs.add(%row)
    var adds = newJArray()
    for row in frame.adds:
      adds.add(%row)
    var pools = newJArray()
    for row in frame.pools:
      pools.add(%row)
    var tel = newJArray()
    for row in frame.tel:
      tel.add(%row)
    var meters = newJArray()
    for row in frame.meters:
      meters.add(%row)
    result.add(%*{
      "t": frame.t, "d": int64(frame.digest), "cogs": cogs,
      "boss": frame.boss, "adds": adds, "pools": pools, "tel": tel,
      "mtr": meters
    })

proc phasesJson(sim: Sim): JsonNode =
  result = newJArray()
  for span in sim.phases:
    result.add(%*{
      "phase": span.phase, "name": span.name, "from": span.fromTick,
      "to": (if span.toTick < 0: max(span.fromTick, sim.tick - 1)
             else: span.toTick)
    })

proc namesJson(sim: Sim): JsonNode =
  var players = newJArray()
  var aliases = newJArray()
  var roles = newJArray()
  var kinds = newJArray()
  for slot, cog in sim.cogs:
    players.add(%sim.names[slot])
    aliases.add(%aliasOf(slot))
    roles.add(%($cog.role))
    kinds.add(%sim.policyKinds[slot])
  %*{
    "players": players, "aliases": aliases, "roles": roles,
    "policy_kinds": kinds, "colors": roleColors()
  }

proc controlsBase64*(sim: Sim): string =
  encode(sim.controls)

proc replayJson*(sim: Sim, results: JsonNode): JsonNode =
  %*{
    "protocol": ReplayProtocol,
    "format_version": ReplayFormatVersion,
    "game_version": GameVersion,
    "seed": sim.config.seed,
    "config": sim.config.configJson(),
    "map": sim.arena.spec,
    "names": namesJson(sim),
    "ticks_per_second": TargetFps,
    "turn_ticks": sim.config.turnTicks,
    "tick_count": sim.tick,
    "phases": phasesJson(sim),
    "controls_b64": controlsBase64(sim),
    "keyframes": keyframesJson(sim),
    "events": sim.events.toJson(),
    "results": results
  }

proc replayBytes*(sim: Sim): string =
  $replayJson(sim, resultsJson(sim))

# ---- reading a replay back --------------------------------------------

proc decodeControls*(payload: string): seq[uint8] =
  let raw = decode(payload)
  result = newSeq[uint8](raw.len)
  for i, ch in raw:
    result[i] = uint8(ch)

proc ordersFromEvents*(replay: JsonNode, seats: int):
    Table[int, seq[Order]] =
  ## Rebuilds the per-turn order table from the `order` records. Orders are
  ## what makes the control layer re-derive the SAME targets, so they are part
  ## of the replay's self-sufficiency, not decoration.
  result = initTable[int, seq[Order]]()
  let eventsNode = replay{"events"}
  if eventsNode == nil or eventsNode.kind != JArray:
    return
  for record in eventsNode:
    if record{"type"}.getStr() != "order":
      continue
    let turn = record{"turn"}.getInt(-1)
    let seat = record{"seat"}.getInt(-1)
    if turn < 0 or seat < 0 or seat >= seats:
      continue
    if not result.hasKey(turn):
      var blank = newSeq[Order](seats)
      result[turn] = blank
    var order = Order(intent: inWait, station: stRanged,
      onTelegraph: rxDodge)
    let (intent, _) = parseIntent(record{"intent"}.getStr())
    let (station, _) = parseStation(record{"station"}.getStr())
    let (reaction, _) = parseReaction(record{"on_telegraph"}.getStr())
    order.intent = intent
    order.station = station
    order.onTelegraph = reaction
    order.target = record{"target"}.getStr()
    order.note = record{"note"}.getStr()
    order.say = record{"say"}.getStr()
    let point = record{"point"}
    if point != nil and point.kind == JArray and point.len >= 2:
      order.px = point[0].getInt()
      order.py = point[1].getInt()
      order.hasPoint = true
    result[turn][seat] = order

proc rederive*(replay: JsonNode, keyframeEvery = TargetFps): Sim =
  ## Re-runs the encounter from `seed` + `map` + `config` + the recorded
  ## orders. The control layer recompiles the same bytes, which is what the
  ## digest comparison then proves.
  let protocol = replay{"protocol"}.getStr()
  if protocol != ReplayProtocol:
    raise newException(RaidError, "unexpected replay protocol: " & protocol)
  let configNode = replay{"config"}
  if configNode == nil or configNode.kind != JObject:
    raise newException(RaidError, "replay has no config")
  var config = configFromJson(configNode)
  config.seed = replay{"seed"}.getInt(0)
  config.tokens = @[]
  let mapNode = replay{"map"}
  if mapNode == nil or mapNode.kind != JObject:
    raise newException(RaidError, "replay has no map")
  let arena = arenaFromSpec(mapNode)
  var sim = initSim(config, arena)
  sim.keyframeEvery = keyframeEvery
  let namesNode = replay{"names"}
  if namesNode != nil:
    let players = namesNode{"players"}
    if players != nil and players.kind == JArray:
      for slot in 0 ..< min(players.len, sim.names.len):
        sim.names[slot] = players[slot].getStr()
    let kinds = namesNode{"policy_kinds"}
    if kinds != nil and kinds.kind == JArray:
      for slot in 0 ..< min(kinds.len, sim.policyKinds.len):
        sim.policyKinds[slot] = kinds[slot].getStr()
  let tickCount = replay{"tick_count"}.getInt(0)
  let table = ordersFromEvents(replay, sim.cogs.len)
  let sources = newSeq[OrderSource](sim.cogs.len)
  let latencies = newSeq[int](sim.cogs.len)
  sim.encounterStart()
  while not sim.done and sim.tick < tickCount:
    if sim.turnBoundary():
      let turn = sim.tick div sim.config.turnTicks
      if table.hasKey(turn):
        sim.installOrders(table[turn], sources, latencies)
    sim.stepOnce()
  sim

proc firstDigestMismatch*(replay: JsonNode, rebuilt: Sim): int =
  ## The tick of the first keyframe whose digest differs, or -1.
  let recorded = replay{"keyframes"}
  if recorded == nil or recorded.kind != JArray:
    return -1
  ## int64, not int: `int` is 32 bits under emscripten and an FNV-1a u32
  ## digest overflows it.
  var byTick = initTable[int, int64]()
  for frame in rebuilt.keyframes:
    byTick[frame.t] = int64(frame.digest)
  for frame in recorded:
    let t = frame{"t"}.getInt(-1)
    if t < 0 or not byTick.hasKey(t):
      continue
    if byTick[t] != frame{"d"}.getBiggestInt():
      return t
  -1

proc controlsMatch*(replay: JsonNode, rebuilt: Sim): bool =
  let recorded = decodeControls(replay{"controls_b64"}.getStr())
  if recorded.len != rebuilt.controls.len:
    return false
  for i in 0 ..< recorded.len:
    if recorded[i] != rebuilt.controls[i]:
      return false
  true
