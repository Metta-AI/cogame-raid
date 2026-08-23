## Shared test helpers. Lives in a SUBDIRECTORY on purpose: ci.yml runs every
## `tests/*.nim` file individually as a standalone program, so a helper module
## must not match that glob.

import std/[json, os, strutils]
import raid/[types, config, state, sim, engine, baselines, scoring, replay]

export types, config, state, sim, engine, baselines, scoring, replay

let sharedArena* = block:
  ## One bake for the whole test program: the prefix-sum occupancy bake is
  ## ~800k pixels and a fresh one per Sim would dominate every test's runtime.
  loadArena("foundry")

proc testConfig*(seed = 42, boss = 26000, enrage = 5760, maxTicks = 6480,
    roles: seq[string] = @["tank", "healer", "dps", "dps", "dps"]):
    GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.bossMaxHp = boss
  result.enrageTicks = enrage
  result.maxTicks = maxTicks
  result.roles = roles
  for i in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(i + 1)))
    result.tokens.add("token-" & $i)

proc certConfig*(): GameConfig =
  ## The certification fixture, exactly as the manifest declares it.
  result = testConfig(seed = 42, boss = 3000, enrage = 960, maxTicks = 1200)
  result.turnBudgetSeconds = 10.0
  result.wallClockBudgetSeconds = 180.0
  result.playerConnectTimeoutSeconds = 60.0

proc newWorld*(config: GameConfig): Sim =
  initSim(config, sharedArena)

proc quietWorld*(seed = 42): Sim =
  ## A world with the boss's schedule pushed out of the way, for unit tests
  ## that want to exercise one mechanic without a cleave landing on it.
  result = newWorld(testConfig(seed = seed))
  result.boss.cleaveCd = 100000
  result.boss.pourCd = 100000
  result.boss.overloadCd = 100000
  result.boss.addsCd = 100000
  result.boss.meleeCd = 100000

proc stand*(world: var Sim, slot, x, y: int) =
  world.cogs[slot].x = x
  world.cogs[slot].y = y
  world.cogs[slot].velX = 0
  world.cogs[slot].velY = 0
  world.cogs[slot].carryX = 0
  world.cogs[slot].carryY = 0
  world.cogs[slot].histX = x
  world.cogs[slot].histY = y

proc setOrder*(world: var Sim, slot: int, order: Order) =
  world.orders[slot] = repairOrder(world, slot, order)
  world.haveOrder[slot] = true

proc holdStill*(world: var Sim, slot: int) =
  world.setOrder(slot, Order(intent: inWait, station: stPoint,
    px: world.cogs[slot].x, py: world.cogs[slot].y, hasPoint: true,
    onTelegraph: rxHold))

proc runScripted*(config: GameConfig, kind: ScriptKind): Sim =
  ## A whole encounter on one scripted baseline, no clock, no network.
  var world = newWorld(config)
  let kinds = @[kind, kind, kind, kind, kind]
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    scriptedDecisions(view, seats, kinds)
  let clock: Clock = proc (): float = 0.0
  runEncounter(world, decide, clock, kinds, nil)
  world

proc runTicks*(world: var Sim, ticks: int) =
  for i in 0 ..< ticks:
    if world.done:
      return
    world.stepOnce()

proc check*(condition: bool, message: string) =
  if not condition:
    echo "FAIL: ", message
    quit(1)

proc checkEq*[T](got, want: T, message: string) =
  if got != want:
    echo "FAIL: ", message, " (got ", got, ", want ", want, ")"
    quit(1)

proc checkNear*(got, want, tolerance: float, message: string) =
  if abs(got - want) > tolerance:
    echo "FAIL: ", message, " (got ", got, ", want ", want, ")"
    quit(1)

proc done*(name: string) =
  echo "ok: ", name

proc repoFile*(path: string): string =
  for prefix in ["", "..", "../.."]:
    let candidate = if prefix.len == 0: path else: prefix / path
    if fileExists(candidate):
      return readFile(candidate)
  raise newException(IOError, "test fixture not found: " & path)

proc eventsOf*(world: Sim, kind: string): seq[JsonNode] =
  for record in world.events.records:
    if record{"type"}.getStr() == kind:
      result.add(record)

proc firstEvent*(world: Sim, kind: string): JsonNode =
  for record in world.events.records:
    if record{"type"}.getStr() == kind:
      return record
  nil

proc countLines*(text, needle: string): int =
  text.count(needle)
