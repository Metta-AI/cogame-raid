## The two scripted baselines.
##
## Both emit the identical order JSON on the same five-second cadence as an
## LLM seat, so their output is legal by construction and directly comparable.
## Both are pure functions of the world state: no randomness beyond the
## episode seed, which is what makes the bounded-orders test meaningful.
##
## `stalwart` is the certification player, the default, and the correct
## execution of the encounter. `greenhorn` is deliberately weaker and
## different in shape so the ladder has a spread: everyone stands in melee,
## everyone dodges everything (so the tank walks its own cleave across the
## raid), nobody interrupts, nobody soaks and adds are ignored.

import std/[strutils]
import types, state, orders, labels

const
  ## Stations the stalwart baseline stands on, tuned against the authored
  ## floor (tools/tune_baselines.nim sweeps them; these are what it kept).
  ##
  ## The tank stands due NORTH of SMELTER-9 so its facing - and therefore
  ## every cleave - points at the empty top of the pit, and close enough to
  ## melee it: the design note's 617,180 is 149 px from a 40 px melee range,
  ## which holds no threat at all, so the ring distance is the melee ring.
  TankStandDy* = 36
  ## The three dps and the healer sit on CARDINALS, never on the diagonals:
  ## the four pillars sit on the diagonals at radius 150 and would cut the
  ## line of sight a ranged attack needs.
  DpsStands*: array[3, array[2, int]] = [
    [PitCx, PitCy + RangedRingPx],
    [PitCx + RangedRingPx, PitCy],
    [PitCx - RangedRingPx, PitCy]
  ]
  ## Meltdown stacks: in phase 3 the three dps bunch inside one crucible's
  ## radius so a 240-damage circle centred on any of them splits three ways
  ## instead of killing whoever it picked. Each stack sits 190+ px from the
  ## boss - outside the 180 px cleave reach - on clear firing lanes, and
  ## there are three of them because a crucible leaves a 10-second pool
  ## exactly where the raid just stood.
  MeltdownStacks*: array[3, array[3, array[2, int]]] = [
    [[617, 529], [657, 545], [577, 545]],
    [[817, 459], [847, 419], [787, 419]],
    [[417, 459], [387, 419], [447, 419]]
  ]
  ## Healer stands, same rotation rule.
  HealerStands*: array[3, array[2, int]] = [
    [617, 440], [760, 420], [474, 420]
  ]

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values. Bullwhip's shape (`src/bullwhip/llm.nim:61`):
  ## "1"/"true"/"yes"/"stalwart" play the stalwart bot, "greenhorn" the weak
  ## one, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "stalwart", "default": skStalwart
  of "greenhorn", "green", "novice": skGreenhorn
  else: skNone

proc liveTelegraphKind(sim: Sim): int =
  ## -1 none, else ord(TelegraphKind).
  if sim.telegraphs.len == 0: -1 else: ord(sim.telegraphs[0].kind)

proc phaseJustStarted(sim: Sim): bool =
  sim.phases.len > 0 and
    sim.phases[^1].fromTick > sim.tick - sim.config.turnTicks

proc addsNear(sim: Sim, slot, radius: int): int =
  for a in sim.adds:
    if a.alive and withinPx(a.x, a.y, sim.cogs[slot].x, sim.cogs[slot].y,
        radius):
      result.inc

proc dpsRank(sim: Sim, slot: int): int =
  ## Which of the three dps this seat is, by slot order. Stable across deaths
  ## so two seats never share a station.
  for i in 0 ..< slot:
    if sim.cogs[i].role == roleDps:
      result.inc

proc pooled(sim: Sim, x, y: int): bool =
  ## Is this spot inside a burning pool, or inside the circle one is about to
  ## become? Reading the floor is part of the skill; the baseline reads it.
  for pool in sim.pools:
    if withinPx(x, y, pool.cx, pool.cy, pool.radius + PlayerHalf):
      return true
  false

proc stackIndex(sim: Sim): int =
  ## The first Meltdown stack whose three spots are all clear of pools.
  for index in 0 ..< MeltdownStacks.len:
    var clear = true
    for spot in MeltdownStacks[index]:
      if pooled(sim, spot[0], spot[1]):
        clear = false
    if clear:
      return index
  0

proc healerStandIndex(sim: Sim): int =
  for index in 0 ..< HealerStands.len:
    if not pooled(sim, HealerStands[index][0], HealerStands[index][1]):
      return index
  0

proc dpsStand(sim: Sim, rank: int): array[2, int] =
  ## The firing position for one dps: a cardinal 260 px lane in Forge and
  ## Slag, the Meltdown stack in phase 3, and in both cases the first
  ## candidate that is not standing in a burning pool.
  var candidates: seq[array[2, int]]
  if sim.boss.phase >= 3:
    for stack in MeltdownStacks:
      candidates.add(stack[rank])
    candidates.add(DpsStands[rank])
  else:
    candidates.add(DpsStands[rank])
    for stack in MeltdownStacks:
      candidates.add(stack[rank])
  for spot in candidates:
    if not pooled(sim, spot[0], spot[1]):
      return spot
  candidates[0]

proc crucibleSoakers(sim: Sim): seq[int] =
  ## Who is ON SOAK DUTY in Meltdown. 240 damage SPLIT between the bodies in
  ## the circle: one dps alone is a corpse, the tank alone survives and then
  ## needs a heal, two cogs eat it cheaply; nobody at all and SMELTER-9 keeps
  ## a permanent +20 % Spill stack. The duty is standing, not reactive - the
  ## fuse is 72 ticks and an order only lands every 120, so the answer has to
  ## be pre-authorised in `on_telegraph` before the circle appears.
  if sim.boss.phase < 3:
    return @[]
  let tank = sim.tankSlot()
  if tank >= 0 and sim.cogs[tank].alive and
      sim.cogs[tank].hp * 10 > sim.cogs[tank].maxHp * 6:
    return @[tank]
  ## No tank left to eat it alone: every living dps shares it (80 each for
  ## three, 120 for two), and the healer stays out - it is the only cog whose
  ## output cannot be replaced.
  for i, cog in sim.cogs:
    if cog.alive and cog.role != roleHealer:
      result.add(i)
  if result.len == 0:
    for i, cog in sim.cogs:
      if cog.alive:
        result.add(i)

proc lowestSlotLivingDps(sim: Sim): int =
  for i, cog in sim.cogs:
    if cog.alive and cog.role == roleDps:
      return i
  -1

proc highestHpLivingDps(sim: Sim): int =
  var best = -1
  for i, cog in sim.cogs:
    if not cog.alive or cog.role != roleDps:
      continue
    if best < 0 or cog.hp > sim.cogs[best].hp:
      best = i
  best

proc anyAllyUnder(sim: Sim, pct: int): bool =
  for cog in sim.cogs:
    if cog.alive and cog.hp * 100 < cog.maxHp * pct:
      return true
  false

proc neediestAlly(sim: Sim): tuple[slot, missing: int] =
  ## The living cog missing the most ABSOLUTE hit points. Triage by missing
  ## hp, not by percentage: a 90 hp heal on a dps at 95 % throws most of
  ## itself away, and the mana pool is the whole encounter's healing budget.
  result = (-1, 0)
  for i, cog in sim.cogs:
    if not cog.alive:
      continue
    let missing = cog.maxHp - cog.hp
    if missing > result.missing:
      result = (i, missing)

proc stalwartTank(sim: Sim, slot: int): Order =
  result = Order(intent: inTankBoss, station: stPoint, target: "boss",
    onTelegraph: rxHold, px: PitCx, py: PitCy - TankStandDy, hasPoint: true,
    note: "north of the boss so the cone points at empty floor",
    say: "cone is north")
  if slot in crucibleSoakers(sim):
    ## Standing soak duty: keep tanking, but step INTO the crucible when it
    ## lands instead of out of it.
    result.onTelegraph = rxSoak
    result.note = "tanking, and I take the crucible when it drops"
    result.say = "crucible on me"
  ## The design note's tank "normally holds cleaves". It cannot, and the
  ## arithmetic says so: 120 hp every 8 s (15 hp/s) on top of 36.7 hp/s of
  ## boss melee is 52 hp/s against a healer whose SUSTAINED ceiling is
  ## 30 mana/s / 60 mana per 90 hp heal = 45 hp/s. Holding is a slow wipe.
  ## Stepping out costs the tank half its melee uptime and buys the raid a
  ## tank that lives to Meltdown; the cone still lands on empty floor,
  ## because the boss's facing is FROZEN for the whole telegraph and the rest
  ## of the raid stands beyond its 180 px reach.
  result.onTelegraph = rxDodge
  if sim.cogs[slot].tauntCd == 0 and
      (sim.boss.target != slot or phaseJustStarted(sim)):
    result.intent = inTaunt
    result.note = "boss is loose or the phase just turned; pulling it back"
    result.say = "taunting now"
    return
  ## No add duty for the tank: leaving the boss costs melee uptime, threat
  ## and the cone's aim, and the three dps clear crawlers far faster.
  discard

const
  HealWorthwhileHp* = 45
    ## Do not spend 60 mana on a cog missing less than this: a 90 hp heal on
    ## a nearly-full cog is mostly overheal, and overheal is what runs the
    ## 1200-point pool dry before Meltdown.
  HealThresholdPct* = 80
  TankPriorityPct* = 45
    ## Below this fraction the tank outranks everyone for the healer's mana.
  ## The design note's stalwart heals "while any ally is under 70%". Tuned to
  ## 80: an order stands for 120 ticks and SMELTER-9 takes 36.7 hp/s off the
  ## tank, so a tank at 71% when the order is cut is at 10% when the next one
  ## lands. 80 is the highest value the grid harness kept that still leaves
  ## the mana pool intact through the phase-2 add waves.

proc stalwartHealer(sim: Sim, slot: int): Order =
  let stand = HealerStands[healerStandIndex(sim)]
  result = Order(intent: inHealLowest, station: stPoint,
    px: stand[0], py: stand[1], hasPoint: true,
    onTelegraph: rxDodge, note: "topping the raid, keeping line of sight",
    say: "healing")
  if slot in crucibleSoakers(sim):
    result.onTelegraph = rxSoak
  ## Triage by role AND by danger: the tank is the only cog whose death turns
  ## the encounter into a scramble, so it wins the mana whenever it is the
  ## one in trouble - but a dps at 100 hp with a pool under it dies faster
  ## than a tank at 150, so below that line the reflexes pick per tick.
  let tank = sim.tankSlot()
  if tank >= 0 and sim.cogs[tank].alive and
      sim.cogs[tank].hp * 100 < sim.cogs[tank].maxHp * TankPriorityPct:
    result.intent = inHealTarget
    result.target = aliasOf(tank)
    result.note = "tank first; it is the only bar whose zero ends the pull"
    result.say = "healing the tank"
    return
  let needy = neediestAlly(sim)
  if needy.slot >= 0 and needy.missing >= HealWorthwhileHp:
    ## Stay on heal_lowest so the controller re-picks the falling cog every
    ## tick; the order only says "keep the raid up", the reflexes choose who.
    result.note = aliasOf(needy.slot) & " is down " & $needy.missing &
      " hp; keeping the raid on its feet"
    result.say = "healing " & aliasOf(needy.slot)
    return
  if anyAllyUnder(sim, HealThresholdPct):
    return
  if tank >= 0 and sim.cogs[tank].alive and sim.cogs[slot].shieldCd == 0 and
      sim.cogs[slot].mana >= ShieldCost and
      liveTelegraphKind(sim) == ord(tkCleave):
    ## Only when nobody needs the heal more: a shield that displaces a heal
    ## on a falling tank is a wipe.
    result.intent = inShieldTarget
    result.target = aliasOf(tank)
    result.note = "cleave incoming; shielding the tank before it lands"
    result.say = "shield on tank"
    return
  result.intent = inConserve
  result.note = "everyone is high; banking mana for Meltdown"
  result.say = "saving mana"

proc stalwartDps(sim: Sim, slot: int): Order =
  let rank = dpsRank(sim, slot) mod DpsStands.len
  let stand =
    if sim.boss.phase >= 3: MeltdownStacks[stackIndex(sim)][rank]
    else: dpsStand(sim, rank)
  result = Order(intent: inBurnBoss, station: stPoint, target: "boss",
    px: stand[0], py: stand[1], hasPoint: true,
    onTelegraph: rxDodge, note: "burning the boss from a clear firing lane",
    say: "on boss")
  if slot in crucibleSoakers(sim):
    result.onTelegraph = rxSoak
    result.note = "burning, and sharing the crucible so nobody eats 240 alone"
    result.say = "crucible with me"
  ## The interrupt claim outranks add duty: a landed Overload costs the raid
  ## 400 boss hp AND 350 raid hp, which is worth more than four seconds of
  ## one dps's damage. One cog owns it for the whole fight so two interrupts
  ## never collide on the same cast.
  if sim.boss.phase >= 2 and lowestSlotLivingDps(sim) == slot:
    result.intent = inInterrupt
    result.target = "boss"
    result.note = "I own the Overload interrupt for the rest of the fight"
    result.say = "I interrupt"
    return
  if sim.addsAlive() >= 1:
    ## Close on the crawler rather than shooting across the pit: a pillar
    ## between a dps and a moving add is most of the reason adds live long
    ## enough for Feed to matter.
    result.intent = inKillAdds
    result.target = ""
    result.note = "crawlers up; clearing them before Feed lands"
    result.say = "killing adds"

proc greenhornOrder(sim: Sim, slot: int): Order =
  ## Melee, dodge everything, never interrupt, never soak, ignore adds.
  case sim.cogs[slot].role
  of roleTank:
    result = Order(intent: inTankBoss, station: stMelee, target: "boss",
      onTelegraph: rxDodge, note: "hitting the boss", say: "on it")
  of roleHealer:
    result = Order(intent: inHealLowest, station: stMelee,
      onTelegraph: rxDodge, note: "healing whoever is lowest", say: "healing")
  of roleDps:
    result = Order(intent: inBurnBoss, station: stMelee, target: "boss",
      onTelegraph: rxDodge, note: "hitting the boss", say: "on it")

proc scriptedOrder*(sim: Sim, slot: int, kind: ScriptKind): Order =
  ## Always legal by construction; `repairOrder` still runs over it so the two
  ## policy kinds go through exactly one code path.
  var raw: Order
  if kind == skGreenhorn:
    raw = greenhornOrder(sim, slot)
  else:
    case sim.cogs[slot].role
    of roleTank: raw = stalwartTank(sim, slot)
    of roleHealer: raw = stalwartHealer(sim, slot)
    of roleDps: raw = stalwartDps(sim, slot)
  repairOrder(sim, slot, raw)
