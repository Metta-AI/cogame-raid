## The mutable world: the `Sim` object, its construction, the state digest and
## the small queries every mechanic module needs.

import std/[json]
import types, config, arena, events, labels

type
  Sim* = object
    config*: GameConfig
    arena*: Arena
    rng*: Pcg32
    tick*: int
    turn*: int
    cogs*: seq[Cog]
    boss*: Boss
    adds*: seq[Add]
    pools*: seq[Pool]
    telegraphs*: seq[Telegraph]
    orders*: seq[Order]
    orderSources*: seq[OrderSource]
    haveOrder*: seq[bool]
    says*: seq[string]          ## the callouts seats read THIS turn
    pendingSays*: seq[string]   ## what this turn's orders said
    events*: EventBuffer
    controls*: seq[uint8]       ## 4 bytes per cog per tick, seat-major
    keyframes*: seq[Keyframe]
    phases*: seq[PhaseSpan]
    names*: seq[string]         ## real policy names, spectator side only
    policyKinds*: seq[string]
    done*: bool
    reason*: string
    endRule*: string
    nextAddId*: int
    nextPoolId*: int
    nextTelegraphId*: int
    wave*: int
    addsKilled*: int
    overloadsResolved*: int
    deaths*: int
    faultDetail*: string
    keyframeEvery*: int         ## 24 for the replay file, 1 for the viewer

const
  LegalReasons* = ["complete", "deadline", "fault"]
  LegalEndRules* = ["kill", "wipe", "enrage_timeout", "wall_clock",
    "sim_fault", "host_error"]

proc dealRoles*(seed: int, pinned: seq[string]): seq[Role] =
  ## `roles` in the config overrides the deal outright (fixtures and tests
  ## want a readable seating); otherwise the five cards are shuffled with a
  ## Fisher-Yates pass on the episode stream.
  if pinned.len == Seats:
    result = @[]
    for role in pinned:
      result.add(parseRole(role))
    return
  var cards = @[roleTank, roleHealer, roleDps, roleDps, roleDps]
  var rng = initPcg32(seed)
  for i in countdown(cards.high, 1):
    let j = rng.below(i + 1)
    let swap = cards[i]
    cards[i] = cards[j]
    cards[j] = swap
  cards

proc newCog*(slot: int, role: Role, x, y: int): Cog =
  Cog(
    slot: slot, role: role, x: x, y: y,
    aim: bearingBrads(PitCx - x, PitCy - y),
    hp: roleMaxHp(role), maxHp: roleMaxHp(role),
    mana: (if role == roleHealer: ManaMax else: 0),
    alive: true, deathTick: -1, castTarget: -1,
    attacking: "", histX: x, histY: y
  )

proc initSim*(config: GameConfig, arena: Arena = nil): Sim =
  var cfg = config
  cfg.validate()
  result.config = cfg
  result.arena = if arena == nil: loadArena(cfg.mapPath) else: arena
  result.rng = initPcg32(cfg.seed)
  ## The role deal draws first, so the pour draws that follow are a stable
  ## continuation of the same stream.
  let roles = dealRoles(cfg.seed, cfg.roles)
  result.cogs = @[]
  for slot in 0 ..< Seats:
    let spawn = result.arena.cogSpawns[slot]
    result.cogs.add(newCog(slot, roles[slot], spawn[0], spawn[1]))
  ## Advance the shared stream past the deal so a pinned `roles` list and a
  ## dealt one draw the same pour targets for a given seed.
  for i in 0 ..< Seats:
    discard result.rng.below(Seats)
  result.boss = Boss(
    x: result.arena.bossStand[0], y: result.arena.bossStand[1],
    aim: 192, hp: cfg.bossMaxHp, maxHp: cfg.bossMaxHp, phase: 1,
    target: 0, cleaveCd: CleaveFirstTick, pourCd: PourFirstTick,
    overloadCd: OverloadCadence, addsCd: AddWaveTicks,
    meleeCd: BossMeleeTicks
  )
  result.orders = newSeq[Order](Seats)
  result.orderSources = newSeq[OrderSource](Seats)
  result.haveOrder = newSeq[bool](Seats)
  result.says = newSeq[string](Seats)
  result.pendingSays = newSeq[string](Seats)
  result.names = @[]
  result.policyKinds = @[]
  for slot in 0 ..< Seats:
    result.names.add("Player " & $(slot + 1))
    result.policyKinds.add("scripted")
    result.orders[slot] = Order(
      intent: defaultIntentFor(roles[slot]),
      station: defaultStationFor(roles[slot]),
      onTelegraph: rxDodge
    )
  if cfg.players.len == Seats:
    for slot in 0 ..< Seats:
      let name = cfg.players[slot].name
      if name.len > 0:
        result.names[slot] = sanitizeName(name, MaxPolicyLabelRunes)
  result.phases = @[PhaseSpan(phase: 1, name: phaseName(1), fromTick: 0,
    toTick: -1)]
  result.nextAddId = 1
  result.nextPoolId = 1
  result.nextTelegraphId = 1
  result.keyframeEvery = TargetFps
  result.reason = ""
  result.endRule = ""

# ---- queries -----------------------------------------------------------

proc aliveCount*(sim: Sim): int =
  for cog in sim.cogs:
    if cog.alive:
      result.inc

proc addsAlive*(sim: Sim): int =
  for a in sim.adds:
    if a.alive:
      result.inc

proc addIndexById*(sim: Sim, id: int): int =
  for i, a in sim.adds:
    if a.id == id:
      return i
  -1

proc livePourTelegraph*(sim: Sim): int =
  ## Index of the live pour/crucible circle, or -1.
  for i, tel in sim.telegraphs:
    if tel.kind != tkCleave:
      return i
  -1

proc nearestLivingAdd*(sim: Sim, x, y: int): int =
  var best = -1
  var bestDist = high(int)
  for i, a in sim.adds:
    if not a.alive:
      continue
    let d = distSq(x, y, a.x, a.y)
    if d < bestDist or (d == bestDist and best >= 0 and a.id < sim.adds[best].id):
      bestDist = d
      best = i
  best

proc lowestHpAlly*(sim: Sim, exclude = -1): int =
  ## Lowest hp fraction among living cogs; ties break to the lower slot.
  var best = -1
  var bestNum = 0
  var bestDen = 1
  for i, cog in sim.cogs:
    if not cog.alive or i == exclude:
      continue
    if best < 0 or cog.hp * bestDen < bestNum * cog.maxHp:
      best = i
      bestNum = cog.hp
      bestDen = cog.maxHp
  best

proc tankSlot*(sim: Sim): int =
  for i, cog in sim.cogs:
    if cog.role == roleTank:
      return i
  -1

proc healerSlot*(sim: Sim): int =
  for i, cog in sim.cogs:
    if cog.role == roleHealer:
      return i
  -1

proc highestThreatLiving*(sim: Sim): int =
  var best = -1
  for i, cog in sim.cogs:
    if not cog.alive:
      continue
    if best < 0 or cog.threat > sim.cogs[best].threat:
      best = i
  best

proc elapsedSeconds*(sim: Sim): float =
  sim.tick.float / TargetFps.float

proc bossHpPct*(sim: Sim): float =
  if sim.boss.maxHp <= 0:
    return 0.0
  100.0 * sim.boss.hp.float / sim.boss.maxHp.float

proc damageMultiplied*(sim: Sim, base: int): int =
  ## final = base x (1 + 0.25 feed) x (1 + 0.20 spill) x (3 if enraged),
  ## integer-truncated at the end. Kept as one integer expression so the
  ## numbers in docs/RULES.md are exactly reproducible.
  var scaled = base * 100
  if sim.boss.feed:
    scaled = scaled * 125 div 100
  if sim.boss.spillStacks > 0:
    scaled = scaled * (100 + 20 * sim.boss.spillStacks) div 100
  if sim.boss.enraged:
    scaled = scaled * 3
  scaled div 100

# ---- state digest ------------------------------------------------------

proc fnv(hash: var uint32, value: int) {.inline.} =
  let v = cast[uint32](value)
  for shift in [0, 8, 16, 24]:
    hash = hash xor ((v shr uint32(shift)) and 0xFF'u32)
    hash = hash * 16777619'u32

proc raidStateDigest*(sim: Sim): uint32 =
  ## FNV-1a over the whole live state. Widened from paintbot's `gameHash`
  ## because the viewer proves it re-derived the encounter against this, and a
  ## digest that skipped the boss schedule would not catch a scheduler change.
  var hash = 2166136261'u32
  hash.fnv(sim.tick)
  for cog in sim.cogs:
    hash.fnv(cog.x); hash.fnv(cog.y)
    hash.fnv(cog.velX); hash.fnv(cog.velY)
    hash.fnv(cog.carryX); hash.fnv(cog.carryY)
    hash.fnv(cog.aim); hash.fnv(cog.hp); hash.fnv(cog.shield)
    hash.fnv(cog.mana); hash.fnv(cog.threat)
    hash.fnv(cog.attackCd); hash.fnv(cog.tauntCd)
    hash.fnv(cog.shieldCd); hash.fnv(cog.interruptCd)
    hash.fnv(ord(cog.casting)); hash.fnv(cog.castTicks)
    hash.fnv(if cog.alive: 1 else: 0)
  hash.fnv(sim.boss.hp); hash.fnv(sim.boss.aim); hash.fnv(sim.boss.target)
  hash.fnv(sim.boss.phase); hash.fnv(sim.boss.meleeCd)
  hash.fnv(sim.boss.cleaveCd); hash.fnv(sim.boss.pourCd)
  hash.fnv(sim.boss.overloadCd); hash.fnv(sim.boss.addsCd)
  hash.fnv(ord(sim.boss.casting)); hash.fnv(sim.boss.castTicks)
  hash.fnv(sim.boss.spillStacks); hash.fnv(sim.boss.tauntLock)
  hash.fnv(if sim.boss.enraged: 1 else: 0)
  hash.fnv(if sim.boss.feed: 1 else: 0)
  for a in sim.adds:
    hash.fnv(a.id); hash.fnv(a.x); hash.fnv(a.y); hash.fnv(a.hp)
    hash.fnv(a.target); hash.fnv(if a.alive: 1 else: 0)
  for pool in sim.pools:
    hash.fnv(pool.id); hash.fnv(pool.cx); hash.fnv(pool.cy)
    hash.fnv(pool.radius); hash.fnv(pool.spawnTick)
  for tel in sim.telegraphs:
    hash.fnv(tel.id); hash.fnv(ord(tel.kind)); hash.fnv(tel.cx)
    hash.fnv(tel.cy); hash.fnv(tel.radius); hash.fnv(tel.facing)
    hash.fnv(tel.fuse); hash.fnv(tel.soakNeeded)
  hash

# ---- events ------------------------------------------------------------

proc record*(sim: var Sim, kind: string, fields: JsonNode) =
  sim.events.emit(sim.tick, kind, fields)

proc guardInvariants*(sim: var Sim): string =
  ## Returns a non-empty description when a sim invariant has been broken.
  for cog in sim.cogs:
    if cog.alive and cog.hp <= 0:
      return "living cog " & aliasOf(cog.slot) & " at hp " & $cog.hp
    if cog.alive and not sim.arena.canOccupyCog(cog.x, cog.y):
      return "cog " & aliasOf(cog.slot) & " outside the pit at " &
        $cog.x & "," & $cog.y
  if sim.boss.hp > sim.boss.maxHp:
    return "boss hp " & $sim.boss.hp & " above max " & $sim.boss.maxHp
  for pool in sim.pools:
    if pool.spawnTick > sim.tick:
      return "pool " & $pool.id & " spawned in the future"
  for tel in sim.telegraphs:
    if tel.fuse < 0:
      return "telegraph " & $tel.id & " has a negative fuse"
  ""
