## Telegraph shapes, fuses and resolution. The radial resolution is
## paintbot's `explodeGrenade` shape: a centre, a radius, an integer
## `dx*dx + dy*dy <= r*r` body test and one damage call per victim in slot
## order.

import std/[json]
import types, state, combat, pools, labels

proc telegraphContains*(sim: Sim, tel: Telegraph, x, y: int): bool =
  case tel.kind
  of tkCleave:
    inCone(sim.boss.x, sim.boss.y, tel.facing, tel.halfBrads, tel.reach, x, y)
  else:
    withinPx(x, y, tel.cx, tel.cy, tel.radius)

proc cleaveLive*(sim: Sim): bool =
  for tel in sim.telegraphs:
    if tel.kind == tkCleave:
      return true
  false

proc startCleave*(sim: var Sim) =
  let id = sim.nextTelegraphId
  sim.nextTelegraphId.inc
  sim.telegraphs.add(Telegraph(
    id: id, kind: tkCleave, cx: sim.boss.x, cy: sim.boss.y,
    facing: sim.boss.aim, halfBrads: CleaveHalfBrads, reach: CleaveReach,
    fuse: CleaveTelegraphTicks, drawnOn: -1
  ))
  sim.record("telegraph", %*{
    "id": id, "kind": "cleave", "centre": [sim.boss.x, sim.boss.y],
    "facing_brads": sim.boss.aim, "half_angle_brads": CleaveHalfBrads,
    "reach": CleaveReach, "fuse_ticks": CleaveTelegraphTicks,
    "soak_needed": 0, "drawn_on": newJNull()
  })

proc drawPourTarget*(sim: var Sim): int =
  ## One living NON-TANK cog, uniformly from the episode stream.
  var candidates: seq[int]
  for i, cog in sim.cogs:
    if cog.alive and cog.role != roleTank:
      candidates.add(i)
  if candidates.len == 0:
    for i, cog in sim.cogs:
      if cog.alive:
        candidates.add(i)
  if candidates.len == 0:
    return -1
  candidates[sim.rng.below(candidates.len)]

proc pourCadence*(phase: int): int {.inline.} =
  if phase >= 3: CrucibleCadence else: PourCadence[phase]

proc startPour*(sim: var Sim, crucible: bool) =
  let slot = sim.drawPourTarget()
  if slot < 0:
    ## Nobody to draw on (everyone dead): re-arm and try again later rather
    ## than spinning on a zero counter.
    sim.boss.pourCd = pourCadence(sim.boss.phase)
    return
  let id = sim.nextTelegraphId
  sim.nextTelegraphId.inc
  let radius = if crucible: CrucibleRadius else: PourRadius
  let fuse = if crucible: CrucibleTelegraphTicks else: PourTelegraphTicks
  let soak = if crucible: 1 else: 0
  sim.telegraphs.add(Telegraph(
    id: id, kind: (if crucible: tkCrucible else: tkPour),
    cx: sim.cogs[slot].x, cy: sim.cogs[slot].y, radius: radius,
    fuse: fuse, soakNeeded: soak, drawnOn: slot
  ))
  sim.record("telegraph", %*{
    "id": id, "kind": (if crucible: "crucible" else: "pour"),
    "centre": [sim.cogs[slot].x, sim.cogs[slot].y], "radius": radius,
    "fuse_ticks": fuse, "soak_needed": soak, "drawn_on": aliasOf(slot)
  })

proc resolveOne(sim: var Sim, tel: Telegraph) =
  var hit: seq[int]
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive:
      continue
    if sim.telegraphContains(tel, sim.cogs[slot].x, sim.cogs[slot].y):
      hit.add(slot)
  var aliases = newJArray()
  for slot in hit:
    aliases.add(%aliasOf(slot))
  var damageEach = 0
  var spillGained = 0
  var poolId = 0
  case tel.kind
  of tkCleave:
    sim.boss.cleaveCd = CleaveCadence[sim.boss.phase]
    damageEach = sim.damageMultiplied(CleaveDamage)
    for slot in hit:
      discard sim.damageCog(slot, damageEach, "cleave", BossName)
      sim.cogs[slot].avoidableHits.inc
  of tkPour:
    sim.boss.pourCd = pourCadence(sim.boss.phase)
    damageEach = sim.damageMultiplied(PourDamage)
    for slot in hit:
      discard sim.damageCog(slot, damageEach, "pour", BossName)
      sim.cogs[slot].avoidableHits.inc
    poolId = sim.spawnPool(tel.cx, tel.cy, tel.radius)
  of tkCrucible:
    sim.boss.pourCd = pourCadence(sim.boss.phase)
    ## No `avoidableHits` here, unlike the cleave and the pour: standing in a
    ## crucible is the CORRECT play (240 damage split beats a permanent Spill
    ## stack), so counting it would make soaking look like a mistake in the
    ## results.
    if hit.len == 0:
      ## Nobody soaked: a permanent Spill stack, and no pool.
      if sim.boss.spillStacks < SpillMaxStacks:
        sim.boss.spillStacks.inc
        spillGained = 1
    else:
      damageEach = sim.damageMultiplied(CrucibleDamage div hit.len)
      for slot in hit:
        discard sim.damageCog(slot, damageEach, "crucible", BossName)
      poolId = sim.spawnPool(tel.cx, tel.cy, tel.radius)
  sim.record("telegraph_resolve", %*{
    "id": tel.id, "kind": $tel.kind, "hit": aliases,
    "damage_each": damageEach, "soakers": hit.len,
    "spill_gained": spillGained, "pool_id": poolId
  })

proc resolveTelegraphs*(sim: var Sim) =
  ## Step 12: every telegraph whose fuse expired this tick, in creation order.
  if sim.telegraphs.len == 0:
    return
  var kept: seq[Telegraph]
  var due: seq[Telegraph]
  for tel in sim.telegraphs:
    if tel.fuse <= 0:
      due.add(tel)
    else:
      kept.add(tel)
  sim.telegraphs = kept
  for tel in due:
    sim.resolveOne(tel)
