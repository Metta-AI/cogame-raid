## Game-owned spectator runtime. Replay rules and controls stay in Raid.
import std/[json, tables]
import types, state, sim, replay, scoring, config, polyworld_presentation

type
  PresentationReplay* = object
    scenes*: seq[RaidScene]
    digests*: seq[uint32]
    summary*: JsonNode

proc loadPresentationReplay*(document: JsonNode): PresentationReplay =
  let reference = rederive(document)
  if firstDigestMismatch(document, reference) != -1 or
      not controlsMatch(document, reference):
    raise newException(RaidError, "replay checkpoints or controls disagree")
  if reference.tick != document["tick_count"].getInt() or not reference.done:
    raise newException(RaidError, "replay is not a complete encounter")
  var world = initSim(reference.config, reference.arena)
  world.keyframeEvery = 1
  let orders = ordersFromEvents(document, Seats)
  let sources = newSeq[OrderSource](Seats)
  let latencies = newSeq[int](Seats)
  world.encounterStart()
  while not world.done:
    if world.turnBoundary():
      let turn = world.tick div world.config.turnTicks
      if orders.hasKey(turn): world.installOrders(orders[turn], sources, latencies)
    world.stepOnce()
    result.scenes.add(projectScene(world))
    # Snapshot clock is t+1; the canonical keyframe belongs to completed step t.
    result.digests.add(world.keyframes[^1].digest)
  if not controlsMatch(document, world):
    raise newException(RaidError, "presentation recompiled different controls")
  let computed = resultsJson(world)
  for key in ["scores", "final_tick", "damage_to_boss", "damage_taken",
      "healing_done", "boss_hp_removed", "kill", "wipe", "end_rule"]:
    if computed[key] != document["results"][key]:
      raise newException(RaidError, "recomputed result differs: " & key)
  result.summary = %*{"terminal_tick": world.tick, "score": world.simScore(),
    "boss_damage": computed["boss_hp_removed"], "end_rule": world.endRule,
    "kill": computed["kill"], "wipe": computed["wipe"]}

proc frameJson*(runtime: PresentationReplay, index: int): JsonNode =
  if index < 0 or index >= runtime.scenes.len:
    raise newException(RaidError, "frame index out of bounds")
  %*{"index": index, "digest": int64(runtime.digests[index]),
    "scene": runtime.scenes[index]}

proc publicReplay*(document: JsonNode): JsonNode =
  ## Construct an allowlisted resource, never publish raw spectator transcripts.
  ## Order notes, policy identity, prompts, credentials and training metadata
  ## are not needed to recompile controls and have no public resource owner.
  let rebuilt = rederive(document)
  if firstDigestMismatch(document, rebuilt) != -1 or not controlsMatch(document, rebuilt):
    raise newException(RaidError, "cannot export an inconsistent replay")
  result = newJObject()
  for key in ["protocol", "format_version", "game_version", "seed", "map",
      "ticks_per_second", "turn_ticks", "tick_count", "phases",
      "controls_b64", "keyframes"]:
    result[key] = document[key]
  result["config"] = configJson(rebuilt.config)
  var players = newJArray()
  var aliases = newJArray()
  for alias in Aliases:
    players.add(%*{"name": alias})
    aliases.add(%alias)
  result["config"]["players"] = players
  result["names"] = %*{"players": aliases, "aliases": aliases}
  result["results"] = resultsJson(rebuilt)
  result["results"]["names"] = aliases
  result["events"] = newJArray()
  for record in document["events"]:
    if record["type"].getStr() == "order":
      var order = newJObject()
      for key in ["t", "type", "turn", "seat", "alias", "intent", "target",
          "station", "point", "on_telegraph", "say", "source", "latency_ms"]:
        if record.hasKey(key): order[key] = record[key]
      result["events"].add(order)
  # The public resource itself must pass, not just the private input.
  discard loadPresentationReplay(result)
