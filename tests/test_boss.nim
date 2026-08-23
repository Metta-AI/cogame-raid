## The boss script, number for number.

import std/[json]
import support/helpers
import raid/[boss, telegraphs, abilities, combat]

proc testPhaseTable() =
  var world = quietWorld()
  world.boss.hp = (world.boss.maxHp * 70) div 100
  world.checkPhase()
  checkEq(world.boss.phase, 1, "exactly 70 % is still Forge")
  world.boss.hp = (world.boss.maxHp * 70) div 100 - 1
  world.checkPhase()
  checkEq(world.boss.phase, 2, "one point under 70 % is Slag")
  world.boss.hp = world.boss.maxHp
  world.checkPhase()
  checkEq(world.boss.phase, 2, "a phase is never re-entered")
  world.boss.hp = (world.boss.maxHp * 35) div 100
  world.checkPhase()
  checkEq(world.boss.phase, 2, "exactly 35 % is still Slag")
  world.boss.hp = (world.boss.maxHp * 35) div 100 - 1
  world.checkPhase()
  checkEq(world.boss.phase, 3, "one point under 35 % is Meltdown")
  done("phase table crosses at exactly 70 % and 35 % and never re-enters")

proc testCleaveCadence() =
  checkEq(CleaveCadence[1], 192, "phase 1 cleave cadence")
  checkEq(CleaveCadence[2], 168, "phase 2 cleave cadence")
  checkEq(CleaveCadence[3], 144, "phase 3 cleave cadence")
  var world = quietWorld()
  for phase in 1 .. 3:
    world.boss.phase = phase
    world.boss.cleaveCd = 0
    world.telegraphs = @[]
    world.startCleave()
    checkEq(world.telegraphs.len, 1, "a cleave telegraph is up")
    world.telegraphs[0].fuse = 0
    world.resolveTelegraphs()
    checkEq(world.boss.cleaveCd, CleaveCadence[phase],
      "the cadence counter restarts from the RESOLUTION in phase " & $phase)
  done("cleave cadence by phase")

proc testCleaveCone() =
  var world = quietWorld()
  world.boss.aim = 64          ## due north
  world.startCleave()
  let tel = world.telegraphs[0]
  ## 179 px directly in front is inside; 181 px is not.
  check(world.telegraphContains(tel, PitCx, PitCy - 179), "179 px is inside")
  check(not world.telegraphContains(tel, PitCx, PitCy - 181),
    "181 px is outside the 180 px reach")
  ## 31 brads off the bisector is inside; 33 brads is not.
  proc atBrad(brad, dist: int): (int, int) =
    (PitCx + BradX[brad] * dist div 1024, PitCy + BradY[brad] * dist div 1024)
  let inside = atBrad(64 + 31, 100)
  let outside = atBrad(64 + 33, 100)
  check(world.telegraphContains(tel, inside[0], inside[1]),
    "31 brads off the bisector is inside")
  check(not world.telegraphContains(tel, outside[0], outside[1]),
    "33 brads off the bisector is outside")
  done("cleave cone is exactly +/-32 brads and 180 px")

proc testFacingFrozenDuringTelegraph() =
  var world = quietWorld()
  world.boss.aim = 64
  world.boss.target = 2
  world.stand(2, PitCx + 200, PitCy)
  world.startCleave()
  let frozen = world.boss.aim
  for i in 0 ..< CleaveTelegraphTicks:
    world.aimBoss()
  checkEq(world.boss.aim, frozen,
    "the boss's facing is frozen for the whole 48-tick telegraph")
  world.telegraphs = @[]
  world.aimBoss()
  check(world.boss.aim != frozen, "and turns again once the cone resolves")
  done("cleave freezes the boss's facing")

proc testPourDrawsOnlyNonTanks() =
  var world = quietWorld()
  for i in 0 ..< 400:
    let slot = world.drawPourTarget()
    check(world.cogs[slot].role != roleTank,
      "a pour never draws the tank (drew slot " & $slot & ")")
  done("pours draw only living non-tank cogs")

proc testPoolBitesAndExpires() =
  var world = quietWorld()
  world.stand(1, PitCx + 200, PitCy)
  world.holdStill(1)
  discard world.spawnPool(PitCx + 200, PitCy, PourRadius)
  let before = world.cogs[1].hp
  world.runTicks(PoolBiteTicks + 1)
  checkEq(before - world.cogs[1].hp, PoolDamage,
    "a pool bites once per 24 ticks")
  world.runTicks(PoolBiteTicks)
  checkEq(before - world.cogs[1].hp, PoolDamage * 2, "and again")
  world.runTicks(PoolTicks)
  checkEq(world.pools.len, 0, "a pool expires at 240 ticks")
  done("pools bite every 24 ticks and expire at 240")

proc testPoolCap() =
  var world = quietWorld()
  for i in 0 ..< PoolCap:
    discard world.spawnPool(PitCx, PitCy + 100 + i, PourRadius)
  checkEq(world.pools.len, PoolCap, "six pools fit")
  let oldest = world.pools[0].id
  discard world.spawnPool(PitCx, PitCy + 200, PourRadius)
  checkEq(world.pools.len, PoolCap, "a seventh does not grow the list")
  for pool in world.pools:
    check(pool.id != oldest, "the oldest pool was the one expired")
  done("the pool cap of six expires the oldest")

proc testOverload() =
  var world = quietWorld()
  world.boss.phase = 2
  world.boss.overloadCd = 0
  world.scheduleBoss()
  checkEq(world.boss.casting, bcOverload, "Overload starts")
  checkEq(world.boss.castTicks, OverloadCastTicks, "as a 96-tick cast")
  world.boss.hp = world.boss.maxHp - 1000
  let hpBefore = world.boss.hp
  var cogHp: array[Seats, int]
  for i in 0 ..< Seats:
    cogHp[i] = world.cogs[i].hp
  world.boss.castTicks = 0
  world.resolveOverload()
  checkEq(world.boss.hp, hpBefore + OverloadHeal, "the boss heals 400")
  for i in 0 ..< Seats:
    checkEq(cogHp[i] - world.cogs[i].hp, OverloadDamage,
      "all five take 70")
  checkEq(world.boss.overloadCd, OverloadCadence, "and it re-arms at 480")
  done("Overload resolves for 70 to all five and 400 back to the boss")

proc testOverloadInterrupted() =
  var world = quietWorld()
  world.boss.phase = 2
  world.boss.overloadCd = 0
  world.scheduleBoss()
  let dps = 2
  world.cogs[dps].role = roleDps
  world.stand(dps, PitCx, PitCy + 200)
  world.cogs[dps].interruptCd = 0
  var control = newSeq[ControlOut](Seats)
  control[dps].action = ActInterrupt
  let hpBefore = world.boss.hp
  world.doInterrupts(control)
  checkEq(world.boss.casting, bcNone, "the cast is cancelled")
  checkEq(world.boss.hp, hpBefore, "the boss heals nothing")
  checkEq(world.boss.overloadCd, OverloadCadence,
    "the next Overload is 480 ticks from the cancellation")
  let record = world.firstEvent("interrupt")
  checkEq(record{"result"}.getStr(), "success", "and it is recorded")
  done("an interrupted Overload does neither")

proc testTwoInterruptsInOneTick() =
  var world = quietWorld()
  world.boss.phase = 2
  world.boss.overloadCd = 0
  world.scheduleBoss()
  for slot in [2, 3]:
    world.cogs[slot].role = roleDps
    world.stand(slot, PitCx, PitCy + 200 + slot)
    world.cogs[slot].interruptCd = 0
  var control = newSeq[ControlOut](Seats)
  control[2].action = ActInterrupt
  control[3].action = ActInterrupt
  world.doInterrupts(control)
  checkEq(world.cogs[2].interruptsLanded, 1, "the lower slot wins")
  checkEq(world.cogs[3].interruptsWasted, 1, "the higher slot is wasted")
  check(world.cogs[3].interruptCd > 0, "and burns its cooldown anyway")
  done("two interrupts on one cast: lower slot wins")

proc testTauntLockAndStickiness() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy - 40)
  world.cogs[0].tauntCd = 0
  world.cogs[3].threat = 1000
  world.boss.target = 3
  var control = newSeq[ControlOut](Seats)
  control[0].action = ActTaunt
  world.doTaunts(control)
  checkEq(world.boss.target, 0, "the taunt pulls the boss")
  checkEq(world.boss.tauntLock, TauntLockTicks, "and locks it for 72 ticks")
  checkEq(world.cogs[0].threat, 1150, "threat becomes 1.15x the highest")
  ## Stickiness: 1.09x does not steal, 1.11x does.
  world.boss.tauntLock = 0
  world.tick = 24
  world.cogs[0].threat = 1000
  world.boss.target = 0
  world.cogs[3].threat = 1090
  world.retargetBoss()
  checkEq(world.boss.target, 0, "1.09x does not steal the boss")
  world.cogs[3].threat = 1110
  world.retargetBoss()
  checkEq(world.boss.target, 3, "1.11x does")
  done("taunt lock and the 10 % stickiness margin")

proc testTauntOnTheTarget() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy - 40)
  world.cogs[0].tauntCd = 0
  world.boss.target = 0
  var control = newSeq[ControlOut](Seats)
  control[0].action = ActTaunt
  world.doTaunts(control)
  let record = world.firstEvent("taunt")
  checkEq(record{"result"}.getStr(), "already_target",
    "a taunt on the cog the boss already holds is recorded as wasted")
  checkEq(world.cogs[0].tauntCd, TauntCooldownTicks,
    "and still burns the cooldown")
  done("a wasted taunt is a real mistake")

proc testAddWavesAndFeed() =
  var world = quietWorld()
  world.boss.phase = 2
  world.boss.addsCd = 0
  world.updateAddWaves()
  checkEq(world.addsAlive(), AddWaveSize, "a wave is two crawlers")
  checkEq(world.boss.addsCd, AddWaveTicks, "on a 360-tick clock")
  for wave in 0 ..< 6:
    world.boss.addsCd = 0
    world.updateAddWaves()
  checkEq(world.addsAlive(), AddCap, "the cap is eight alive")
  world.updateFeed()
  check(world.boss.feed, "Feed is on at four or more")
  for i in 0 ..< world.adds.len - 3:
    world.adds[i].alive = false
  checkEq(world.addsAlive(), 3, "three left")
  world.updateFeed()
  check(not world.boss.feed, "Feed is off under four")
  done("add waves, the cap of eight and the Feed threshold of four")

proc testAddsOnlyInPhaseTwo() =
  var world = quietWorld()
  world.boss.phase = 1
  world.boss.addsCd = 0
  world.updateAddWaves()
  checkEq(world.addsAlive(), 0, "no waves in Forge")
  world.boss.phase = 3
  world.boss.addsCd = 0
  world.updateAddWaves()
  checkEq(world.addsAlive(), 0,
    "and none on the phase-3 clock: Meltdown gets one wave at ENTRY only")
  world.enterPhase(3)
  checkEq(world.addsAlive(), AddWaveSize, "which enterPhase spawns")
  done("add waves are a phase-2 clock plus one wave at phase-3 entry")

proc testEnrage() =
  var world = newWorld(testConfig())
  world.boss.cleaveCd = 100000
  world.boss.pourCd = 100000
  world.boss.overloadCd = 100000
  world.boss.addsCd = 100000
  world.boss.meleeCd = 100000
  world.tick = world.config.enrageTicks - 1
  world.runTicks(1)
  check(not world.boss.enraged, "not enraged a tick early")
  world.runTicks(1)
  check(world.boss.enraged, "enrage fires at tick 5760")
  checkEq(world.damageMultiplied(100), 300, "and triples damage")
  check(world.firstEvent("enrage") != nil, "and is evented once")
  done("enrage at tick 5760")

proc testBossWhiffsOutOfReach() =
  var world = quietWorld()
  world.boss.meleeCd = 0
  world.boss.target = 0
  world.stand(0, PitCx, PitCy + 200)
  let before = world.cogs[0].hp
  world.bossAndAddAttacks()
  checkEq(world.cogs[0].hp, before, "a swing out of reach does nothing")
  let record = world.firstEvent("boss_hit")
  checkEq(record{"amount"}.getInt(), 0, "and is recorded as a whiff")
  done("kiting the boss out of melee is legal")

when isMainModule:
  testPhaseTable()
  testCleaveCadence()
  testCleaveCone()
  testFacingFrozenDuringTelegraph()
  testPourDrawsOnlyNonTanks()
  testPoolBitesAndExpires()
  testPoolCap()
  testOverload()
  testOverloadInterrupted()
  testTwoInterruptsInOneTick()
  testTauntLockAndStickiness()
  testTauntOnTheTarget()
  testAddWavesAndFeed()
  testAddsOnlyInPhaseTwo()
  testEnrage()
  testBossWhiffsOutOfReach()
  echo "test_boss: the whole boss script checks out"
