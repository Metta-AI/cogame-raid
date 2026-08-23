## SMELTER-9: the phase clock, the ability scheduler, threat and retargeting,
## the Slag Crawlers and the boss's own swing. The boss never adapts — every
## number here is published in docs/RULES.md.

import std/[json]
import types, state, combat, telegraphs, labels

proc tickBossTimers*(sim: var Sim) =
  if sim.boss.meleeCd > 0: sim.boss.meleeCd.dec
  if sim.boss.cleaveCd > 0: sim.boss.cleaveCd.dec
  if sim.boss.pourCd > 0: sim.boss.pourCd.dec
  if sim.boss.overloadCd > 0: sim.boss.overloadCd.dec
  if sim.boss.addsCd > 0: sim.boss.addsCd.dec
  if sim.boss.tauntLock > 0: sim.boss.tauntLock.dec
  for i in 0 ..< sim.adds.len:
    if sim.adds[i].attackCd > 0:
      sim.adds[i].attackCd.dec

proc aimBoss*(sim: var Sim) =
  ## Step 4: the boss turns toward its target unless a cleave telegraph is
  ## live, in which case its facing is FROZEN — that is what makes
  ## side-stepping a cone work.
  if sim.cleaveLive():
    return
  let target = sim.boss.target
  if target < 0 or target >= sim.cogs.len or not sim.cogs[target].alive:
    return
  let wanted = bearingBrads(sim.cogs[target].x - sim.boss.x,
    sim.cogs[target].y - sim.boss.y)
  sim.boss.aim = turnToward(sim.boss.aim, wanted, BossTurnRate)

proc retargetBoss*(sim: var Sim) =
  ## Step 10: on every 24th tick, the highest-threat living cog takes over,
  ## but only when it beats the current target by more than 10 %.
  if sim.tick mod TargetFps != 0 or sim.boss.tauntLock > 0:
    return
  let best = sim.highestThreatLiving()
  if best < 0:
    return
  let current = sim.boss.target
  if current < 0 or current >= sim.cogs.len or not sim.cogs[current].alive:
    sim.boss.target = best
    return
  if best == current:
    return
  if sim.cogs[best].threat * 100 > sim.cogs[current].threat * 110:
    sim.boss.target = best

proc alcoveOrderFurthestFromTarget(sim: Sim): seq[int] =
  ## Alcove indexes sorted by descending distance from the boss's current
  ## target; ties keep alcove order, so the wave is reproducible.
  let target = sim.boss.target
  let tx = if target >= 0 and target < sim.cogs.len: sim.cogs[target].x
           else: sim.boss.x
  let ty = if target >= 0 and target < sim.cogs.len: sim.cogs[target].y
           else: sim.boss.y
  var order: seq[int]
  for i in 0 ..< sim.arena.addAlcoves.len:
    order.add(i)
  for i in 1 ..< order.len:
    var j = i
    while j > 0:
      let a = order[j - 1]
      let b = order[j]
      let da = distSq(tx, ty, sim.arena.addAlcoves[a][0],
        sim.arena.addAlcoves[a][1])
      let db = distSq(tx, ty, sim.arena.addAlcoves[b][0],
        sim.arena.addAlcoves[b][1])
      if db > da:
        order[j - 1] = b
        order[j] = a
        j.dec
      else:
        break
  order

proc spawnAddWave*(sim: var Sim) =
  let room = AddCap - sim.addsAlive()
  if room <= 0:
    return
  let count = min(AddWaveSize, room)
  let order = alcoveOrderFurthestFromTarget(sim)
  sim.wave.inc
  var ids = newJArray()
  var positions = newJArray()
  for k in 0 ..< count:
    let alcove = sim.arena.addAlcoves[order[k mod order.len]]
    let id = sim.nextAddId
    sim.nextAddId.inc
    sim.adds.add(Add(
      id: id, x: alcove[0], y: alcove[1], hp: AddHp, alive: true,
      target: -1, attackCd: 0, histX: alcove[0], histY: alcove[1]
    ))
    ids.add(%addName(id))
    positions.add(%*[alcove[0], alcove[1]])
  sim.record("adds_spawn", %*{
    "wave": sim.wave, "ids": ids, "positions": positions,
    "alive_after": sim.addsAlive()
  })

proc updateFeed*(sim: var Sim) =
  let alive = sim.addsAlive()
  let wanted = alive >= FeedThreshold
  if wanted != sim.boss.feed:
    sim.boss.feed = wanted
    sim.record("feed_buff", %*{"active": wanted, "adds_alive": alive})

proc retargetAdds*(sim: var Sim) =
  if sim.tick mod TargetFps != 0:
    return
  for i in 0 ..< sim.adds.len:
    if not sim.adds[i].alive:
      continue
    var best = -1
    var bestThreat = -1
    for slot, cog in sim.cogs:
      if not cog.alive:
        continue
      if not withinPx(sim.adds[i].x, sim.adds[i].y, cog.x, cog.y,
          AddRetargetRange):
        continue
      if cog.threat > bestThreat:
        bestThreat = cog.threat
        best = slot
    if best < 0:
      var bestDist = high(int)
      for slot, cog in sim.cogs:
        if not cog.alive:
          continue
        let d = distSq(sim.adds[i].x, sim.adds[i].y, cog.x, cog.y)
        if d < bestDist:
          bestDist = d
          best = slot
    sim.adds[i].target = best

proc scheduleBoss*(sim: var Sim) =
  ## Step 11: at most one boss ability is ever in flight. Priority is
  ## Overload > Crucible/Slag Pour > Cleave.
  if sim.boss.hp <= 0:
    return
  if sim.boss.casting != bcNone or sim.telegraphs.len > 0:
    return
  let phase = sim.boss.phase
  if phase >= 2 and sim.boss.overloadCd <= 0:
    sim.boss.casting = bcOverload
    sim.boss.castTicks = OverloadCastTicks
    sim.boss.castTotal = OverloadCastTicks
    sim.record("cast_start", %*{
      "ability": "overload", "cast_ticks": OverloadCastTicks,
      "interruptible": true
    })
    return
  if sim.boss.pourCd <= 0:
    sim.startPour(phase >= 3)
    return
  if sim.boss.cleaveCd <= 0:
    sim.startCleave()
    return
  ## Adds are on their own clock and do not occupy the ability slot.
  discard

proc updateAddWaves*(sim: var Sim) =
  if sim.boss.phase == 2 and sim.boss.addsCd <= 0:
    sim.boss.addsCd = AddWaveTicks
    sim.spawnAddWave()

proc resolveOverload*(sim: var Sim) =
  ## The cast landed: 70 to all five and 400 hp back to the boss.
  if sim.boss.casting != bcOverload or sim.boss.castTicks > 0:
    return
  sim.boss.casting = bcNone
  sim.boss.castTotal = 0
  sim.boss.overloadCd = OverloadCadence
  sim.overloadsResolved.inc
  let damage = sim.damageMultiplied(OverloadDamage)
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].alive:
      discard sim.damageCog(slot, damage, "overload", BossName)
  sim.healBoss(OverloadHeal)
  ## One aggregate record on top of the five per-cog ones damageCog already
  ## emitted: Overload is a single raid-wide event and the feed reads this to
  ## say so in one line. `"raid"` is the only target string in the transcript
  ## that is not a cog alias; docs/PROTOCOL.md says so.
  sim.record("boss_hit", %*{
    "target": "raid", "ability": "overload", "amount": damage,
    "absorbed": 0, "hp_left": sim.boss.hp
  })

proc bossAndAddAttacks*(sim: var Sim) =
  ## Step 14.
  if sim.boss.hp > 0 and sim.boss.meleeCd <= 0:
    sim.boss.meleeCd =
      if sim.boss.enraged: BossMeleeTicksEnraged else: BossMeleeTicks
    let target = sim.boss.target
    if target >= 0 and target < sim.cogs.len and sim.cogs[target].alive and
        withinPx(sim.boss.x, sim.boss.y, sim.cogs[target].x,
          sim.cogs[target].y, BossMeleeRange):
      let damage = sim.damageMultiplied(BossMeleeDamage)
      ## No record here: `damageCog` self-events every instance of 40 or more
      ## (`combat.nim:32`) and a swing is 55 before any multiplier, every one
      ## of which is >= 1, so the landed swing is already in the transcript
      ## exactly once. The whiff below is the only case that needs its own.
      discard sim.damageCog(target, damage, "swing", BossName)
    else:
      sim.record("boss_hit", %*{
        "target": (if target >= 0: aliasOf(target) else: ""),
        "ability": "swing", "amount": 0, "absorbed": 0,
        "hp_left": (if target >= 0: max(0, sim.cogs[target].hp) else: 0)
      })
  for i in 0 ..< sim.adds.len:
    if not sim.adds[i].alive or sim.adds[i].attackCd > 0:
      continue
    let target = sim.adds[i].target
    if target < 0 or target >= sim.cogs.len or not sim.cogs[target].alive:
      continue
    if not withinPx(sim.adds[i].x, sim.adds[i].y, sim.cogs[target].x,
        sim.cogs[target].y, AddRange):
      continue
    sim.adds[i].attackCd = AddAttackTicks
    discard sim.damageCog(target, AddDamage, "add",
      addName(sim.adds[i].id))

proc enterPhase*(sim: var Sim, phase: int) =
  ## A phase transition zeroes every schedule counter and restarts it.
  sim.boss.phase = phase
  sim.boss.cleaveCd = CleaveCadence[phase]
  sim.boss.pourCd = pourCadence(phase)
  sim.boss.overloadCd = OverloadCadence
  sim.boss.addsCd = AddWaveTicks
  if sim.phases.len > 0:
    sim.phases[^1].toTick = sim.tick - 1
  sim.phases.add(PhaseSpan(phase: phase, name: phaseName(phase),
    fromTick: sim.tick, toTick: -1))
  sim.record("phase_start", %*{
    "phase": phase, "name": phaseName(phase), "boss_hp": sim.boss.hp,
    "boss_hp_pct": sim.bossHpPct(), "elapsed_s": sim.elapsedSeconds()
  })
  if phase >= 2:
    sim.spawnAddWave()

proc checkPhase*(sim: var Sim) =
  ## Step 16: one-way, never re-entered.
  if sim.boss.hp <= 0:
    return
  let pct = sim.boss.hp * 100 div max(1, sim.boss.maxHp)
  if sim.boss.phase < 2 and pct < 70:
    sim.enterPhase(2)
  if sim.boss.phase < 3 and pct < 35:
    sim.enterPhase(3)
