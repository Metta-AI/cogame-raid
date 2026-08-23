## The bounded-orders / legality assertion on the scripted baselines, and the
## ladder-spread property that makes them useful as fillers.

import std/[unicode]
import std/[json]
import support/helpers
import raid/[control, abilities, telegraphs, boss]

proc perturb(world: var Sim, rng: var Pcg32) =
  ## A pseudo-random but legal world state: positions on free floor, hit
  ## points anywhere, a phase, adds, pools and maybe a live telegraph.
  world.tick = rng.below(6480)
  world.boss.phase = 1 + rng.below(3)
  world.boss.hp = rng.below(world.boss.maxHp + 1)
  world.boss.target = rng.below(Seats)
  world.boss.enraged = rng.below(2) == 0
  world.boss.spillStacks = rng.below(SpillMaxStacks + 1)
  for slot in 0 ..< Seats:
    var x = 0
    var y = 0
    while true:
      x = PitCx - 280 + rng.below(561)
      y = PitCy - 280 + rng.below(561)
      if world.arena.canOccupyCog(x, y):
        break
    world.stand(slot, x, y)
    world.cogs[slot].alive = rng.below(10) > 0
    world.cogs[slot].hp =
      if world.cogs[slot].alive: 1 + rng.below(world.cogs[slot].maxHp)
      else: 0
    world.cogs[slot].threat = rng.below(50000)
    world.cogs[slot].tauntCd = rng.below(TauntCooldownTicks + 1)
    world.cogs[slot].shieldCd = rng.below(ShieldCooldownTicks + 1)
    world.cogs[slot].interruptCd = rng.below(InterruptCooldownTicks + 1)
    world.cogs[slot].attackCd = rng.below(25)
    if world.cogs[slot].role == roleHealer:
      world.cogs[slot].mana = rng.below(ManaMax + 1)
  ## At least one cog alive, or there is nothing to order.
  world.cogs[rng.below(Seats)].alive = true
  world.adds = @[]
  for i in 0 ..< rng.below(AddCap + 1):
    let alcove = world.arena.addAlcoves[i mod world.arena.addAlcoves.len]
    world.adds.add(Add(id: i + 1, x: alcove[0], y: alcove[1],
      hp: 1 + rng.below(AddHp), alive: true, target: rng.below(Seats)))
  world.pools = @[]
  for i in 0 ..< rng.below(PoolCap + 1):
    world.pools.add(Pool(id: i + 1, cx: PitCx - 100 + rng.below(201),
      cy: PitCy - 100 + rng.below(201), radius: PourRadius,
      spawnTick: max(0, world.tick - rng.below(PoolTicks)), alive: true))
  world.telegraphs = @[]
  case rng.below(4)
  of 0:
    world.telegraphs.add(Telegraph(id: 1, kind: tkCleave, cx: world.boss.x,
      cy: world.boss.y, facing: rng.below(256), halfBrads: CleaveHalfBrads,
      reach: CleaveReach, fuse: 1 + rng.below(CleaveTelegraphTicks),
      drawnOn: -1))
  of 1:
    world.telegraphs.add(Telegraph(id: 1, kind: tkPour,
      cx: PitCx - 150 + rng.below(301), cy: PitCy - 150 + rng.below(301),
      radius: PourRadius, fuse: 1 + rng.below(PourTelegraphTicks),
      drawnOn: 1))
  of 2:
    world.telegraphs.add(Telegraph(id: 1, kind: tkCrucible,
      cx: PitCx - 150 + rng.below(301), cy: PitCy - 150 + rng.below(301),
      radius: CrucibleRadius, fuse: 1 + rng.below(CrucibleTelegraphTicks),
      soakNeeded: 1, drawnOn: 2))
  else:
    discard
  if rng.below(3) == 0:
    world.boss.casting = bcOverload
    world.boss.castTicks = 1 + rng.below(OverloadCastTicks)
  else:
    world.boss.casting = bcNone
    world.boss.castTicks = 0

proc testBoundedLegalOrders() =
  var rng = initPcg32(31337)
  var checked = 0
  for kind in [skStalwart, skGreenhorn]:
    for deal in [@["tank", "healer", "dps", "dps", "dps"],
                 @["dps", "dps", "tank", "healer", "dps"],
                 @["healer", "dps", "dps", "dps", "tank"]]:
      var world = newWorld(testConfig(roles = deal))
      for trial in 0 ..< 500 div 3 + 1:
        world.perturb(rng)
        for slot in 0 ..< Seats:
          if not world.cogs[slot].alive:
            continue
          let order = scriptedOrder(world, slot, kind)
          let problem = validateOrder(world, slot, order)
          checkEq(problem, "",
            $kind & " " & $world.cogs[slot].role & " emitted an illegal order")
          check(order.note.runeLen <= MaxNoteRunes, "note within 160 runes")
          check(order.say.runeLen <= MaxSayRunes, "say within 32 runes")
          world.orders[slot] = order
          checked.inc
        ## And the COMPILED control bytes are in range on every tick of the
        ## turn, with no role ever setting a bit it does not own.
        for tick in 0 ..< 8:
          for slot in 0 ..< Seats:
            if not world.cogs[slot].alive:
              continue
            let control = compileControl(world, slot, tick == 0)
            check(control.moveX >= -100 and control.moveX <= 100,
              "move_x in range")
            check(control.moveY >= -100 and control.moveY <= 100,
              "move_y in range")
            check(control.aimTurn >= -AimTurnRate and
              control.aimTurn <= AimTurnRate, "aim_turn within +/-8")
            check(control.action >= 0 and control.action <= 0b11111,
              "action bits inside the five defined bits")
            let role = world.cogs[slot].role
            if role != roleTank:
              check(not hasBit(control.action, ActTaunt),
                "only a tank taunts")
            if role != roleHealer:
              check(not hasBit(control.action, ActHeal), "only a healer heals")
              check(not hasBit(control.action, ActShield),
                "only a healer shields")
            if role != roleDps:
              check(not hasBit(control.action, ActInterrupt),
                "only a dps interrupts")
          world.stepOnce()
  check(checked > 1000, "the sweep actually exercised the baselines")
  done("500 pseudo-random states x both baselines x all three deals")

proc testNoAbilityFiresOnCooldown() =
  var rng = initPcg32(999)
  for kind in [skStalwart, skGreenhorn]:
    var world = newWorld(testConfig())
    for trial in 0 ..< 60:
      world.perturb(rng)
      for slot in 0 ..< Seats:
        if world.cogs[slot].alive:
          world.orders[slot] = scriptedOrder(world, slot, kind)
      for slot in 0 ..< Seats:
        if not world.cogs[slot].alive:
          continue
        let control = compileControl(world, slot, true)
        if hasBit(control.action, ActTaunt):
          checkEq(world.cogs[slot].tauntCd, 0, "no taunt on cooldown")
        if hasBit(control.action, ActShield):
          checkEq(world.cogs[slot].shieldCd, 0, "no shield on cooldown")
        if hasBit(control.action, ActInterrupt):
          checkEq(world.cogs[slot].interruptCd, 0, "no interrupt on cooldown")
        if hasBit(control.action, ActAttack):
          checkEq(world.cogs[slot].attackCd, 0, "no attack on cooldown")
  done("no baseline ever fires an ability on cooldown")

proc testCertificationKill() =
  ## The happy path certification exercises: five stalwart seats kill a
  ## 3000-hp SMELTER-9 well inside the fixture's 1200-tick budget.
  let world = runScripted(certConfig(), skStalwart)
  checkEq(world.reason, "complete", "the certification fixture completes")
  checkEq(world.endRule, "kill", "on a kill")
  check(world.tick < 1200, "inside the fixture's tick budget")
  check(world.aliveCount() >= 1, "with the raid standing")
  check(world.simScore() > 1.0, "scoring above 1.0")
  done("five stalwart seats kill the certification boss")

proc testStalwartBeatsGreenhorn() =
  ## The baselines are ORDERED, so the ladder has a spread. Checked on four
  ## seeds so the ordering is a property, not a coincidence.
  for seed in [42, 7, 1234, 999]:
    let config = testConfig(seed = seed)
    let strong = runScripted(config, skStalwart)
    let weak = runScripted(config, skGreenhorn)
    check(strong.simScore() > weak.simScore() * 2.0,
      "stalwart more than doubles greenhorn's score at seed " & $seed &
      " (" & $strong.simScore() & " vs " & $weak.simScore() & ")")
    check(strong.boss.hp < weak.boss.hp,
      "stalwart takes more of the boss down at seed " & $seed)
    check(strong.boss.phase >= weak.boss.phase,
      "and reaches at least as deep a phase at seed " & $seed)
    checkEq(weak.boss.phase, 1,
      "greenhorn never leaves Forge at seed " & $seed)
  done("stalwart strictly out-plays greenhorn")

proc testStalwartPlaysTheEncounter() =
  ## Not just "scores more": the strong baseline actually does the things the
  ## encounter is about.
  let world = runScripted(testConfig(), skStalwart)
  check(world.eventsOf("taunt").len > 0, "the tank taunts")
  check(world.eventsOf("heal").len > 10, "the healer heals")
  check(world.eventsOf("telegraph_resolve").len > 3, "mechanics resolve")
  check(world.addsKilled > 0, "crawlers die")
  checkEq(world.overloadsResolved, 0,
    "and every Overload is interrupted rather than landing")
  done("stalwart plays the encounter, not just the boss")

proc testStalwartSoaksCrucibles() =
  ## Soak duty in Meltdown is a STANDING assignment, not a comment: the
  ## reaction the tank actually emits has to be `soak`, or every crucible
  ## resolves empty and SMELTER-9 banks a permanent Spill stack.
  var world = newWorld(testConfig())
  world.boss.phase = 3
  world.boss.hp = world.boss.maxHp div 4
  let tank = world.tankSlot()
  let healer = world.healerSlot()
  let healthy = scriptedOrder(world, tank, skStalwart)
  checkEq($healthy.onTelegraph, "soak",
    "a healthy phase-3 tank takes the crucible")
  checkEq($scriptedOrder(world, healer, skStalwart).onTelegraph, "dodge",
    "and the healer stays out of it")
  ## Under 60 % the tank cannot eat 240 alone, so the duty spreads to the dps.
  world.cogs[tank].hp = world.cogs[tank].maxHp div 2
  for slot in 0 ..< Seats:
    if world.cogs[slot].role == roleDps:
      checkEq($scriptedOrder(world, slot, skStalwart).onTelegraph, "soak",
        "with the tank low the dps share the circle")
  checkEq($scriptedOrder(world, healer, skStalwart).onTelegraph, "dodge",
    "the healer never soaks; its output cannot be replaced")
  ## Before Meltdown nobody soaks - there is no crucible to soak.
  world.boss.phase = 2
  world.cogs[tank].hp = world.cogs[tank].maxHp
  checkEq($scriptedOrder(world, tank, skStalwart).onTelegraph, "dodge",
    "and outside Meltdown the tank dodges, cleaves included")
  ## End to end: over a full stalwart episode every crucible that resolves
  ## finds a body in it, so the boss banks no Spill stack.
  let played = runScripted(testConfig(), skStalwart)
  var crucibles = 0
  for record in played.eventsOf("telegraph_resolve"):
    if record{"kind"}.getStr() != "crucible":
      continue
    crucibles.inc
    check(record{"soakers"}.getInt() >= 1,
      "crucible " & $record{"id"}.getInt() & " resolved with nobody in it")
  check(crucibles > 0, "the episode reached Meltdown and poured a crucible")
  checkEq(played.boss.spillStacks, 0, "so SMELTER-9 banks no Spill stack")
  done("stalwart soaks the crucible instead of banking Spill for the boss")

when isMainModule:
  testBoundedLegalOrders()
  testNoAbilityFiresOnCooldown()
  testCertificationKill()
  testStalwartBeatsGreenhorn()
  testStalwartPlaysTheEncounter()
  testStalwartSoaksCrucibles()
  echo "test_baselines: the scripted baselines are bounded, legal and ordered"
