## Normal-input offline recorder. No certification overrides or state edits.
import std/[json, times]
import raid/[sim, engine, baselines, scoring, replay, polyworld_presentation,
  polyworld_replay]

const TerminalSeeds* = [42, 7, 123]

proc snapshot(world: Sim): JsonNode =
  %*{"tick": world.tick, "digest": int64(world.raidStateDigest()),
    "done": world.done, "reason": world.reason, "end_rule": world.endRule,
    "boss": world.boss, "cogs": world.cogs, "adds": world.adds,
    "pools": world.pools, "telegraphs": world.telegraphs, "rng": world.rng,
    "scene": projectScene(world)}

proc recordTerminalFixture*(seed: int, arena: Arena): JsonNode =
  var config = defaultGameConfig()
  config.seed = seed
  for alias in Aliases: config.players.add(PlayerConfig(name: alias))
  var world = initSim(config, arena)
  let initial = snapshot(world)
  let kinds = @[skStalwart, skStalwart, skStalwart, skStalwart, skStalwart]
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    scriptedDecisions(view, seats, kinds)
  let clock: Clock = proc (): float = epochTime()
  runEncounter(world, decide, clock, kinds)
  %*{"controller": "shipped stalwart, normal cadence, seeded role deal",
    "initial": initial, "terminal": snapshot(world),
    "replay": replayJson(world, resultsJson(world))}

proc verifyTerminalFixture*(fixture: JsonNode): JsonNode =
  let document = fixture["replay"]
  var rebuilt = rederive(document)
  if not rebuilt.done or rebuilt.reason != "complete":
    raise newException(RaidError, "fixture did not reach an engine terminal")
  if firstDigestMismatch(document, rebuilt) != -1 or
      not controlsMatch(document, rebuilt):
    raise newException(RaidError, "fixture input/checkpoints disagree")
  let defaults = defaultGameConfig()
  if rebuilt.config.bossMaxHp != defaults.bossMaxHp or
      rebuilt.config.enrageTicks != defaults.enrageTicks or
      rebuilt.config.maxTicks != defaults.maxTicks or
      rebuilt.config.turnTicks != defaults.turnTicks or
      rebuilt.config.roles.len != 0:
    raise newException(RaidError, "fixture is not the default seeded encounter")
  let initial = initSim(rebuilt.config, rebuilt.arena)
  if snapshot(initial) != fixture["initial"] or
      snapshot(rebuilt) != fixture["terminal"]:
    raise newException(RaidError, "initial/terminal state does not rederive")
  let before = snapshot(rebuilt)
  let controls = rebuilt.controls
  rebuilt.stepOnce()
  if snapshot(rebuilt) != before or rebuilt.controls != controls:
    raise newException(RaidError, "terminal step changed state or input count")
  let publicDocument = publicReplay(document)
  let runtime = loadPresentationReplay(publicDocument)
  let last = runtime.scenes.high
  if last != rebuilt.tick - 1 or runtime.scenes[last] != projectScene(rebuilt):
    raise newException(RaidError, "terminal presentation clock/state differs")
  if (rebuilt.endRule == "kill") != (rebuilt.boss.hp <= 0) or
      (rebuilt.endRule == "wipe") !=
        (rebuilt.boss.hp > 0 and rebuilt.aliveCount() == 0):
    raise newException(RaidError, "terminal result misattributes victory/wipe")
  var frames = newJArray()
  for index in [0, max(0, last - 1), last]:
    frames.add(runtime.frameJson(index))
  %*{"state": "pass", "seed": rebuilt.config.seed,
    "summary": runtime.summary, "initial_tick": 0,
    "last_frame": last, "terminal_tick": rebuilt.tick,
    "post_terminal_unchanged": true, "control_bytes": controls.len,
    "terminal_hazards": runtime.scenes[last].hazards,
    "terminal_interrupts": runtime.scenes[last].interrupts,
    "frames": frames, "public_replay": publicDocument}
