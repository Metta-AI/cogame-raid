## Sim unit tests on damage: the absorb funnel, auto-attacks, threat, heals,
## mana, shields and the multiplier order.

import support/helpers
import std/[json]
import raid/[combat, abilities, control]

proc testShieldBeforeHp() =
  var world = quietWorld()
  world.cogs[0].shield = 40
  world.cogs[0].shieldTicks = ShieldExpireTicks
  let outcome = world.damageCog(0, 100, "swing", BossName)
  checkEq(outcome.absorbed, 40, "the shield is spent first")
  checkEq(world.cogs[0].hp, TankMaxHp - 60, "the rest lands on hit points")
  checkEq(world.cogs[0].shield, 0, "the shield drops exactly at 0")
  checkEq(world.cogs[0].shieldTicks, 0, "and stops ageing")
  done("absorbDamage spends shield before hp")

proc testShieldExactlyCovers() =
  var world = quietWorld()
  world.cogs[2].shield = 34
  world.cogs[2].shieldTicks = ShieldExpireTicks
  discard world.damageCog(2, 34, "cleave", BossName)
  checkEq(world.cogs[2].hp, world.cogs[2].maxHp, "no hit points lost")
  checkEq(world.cogs[2].shield, 0, "the shield is exactly consumed")
  done("a shield that exactly covers a hit drops to zero")

proc testTankAutoAttack() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy - 36)
  world.setOrder(0, Order(intent: inTankBoss, target: "boss",
    station: stPoint, px: PitCx, py: PitCy - 36, hasPoint: true,
    onTelegraph: rxHold))
  for slot in 1 ..< Seats:
    world.cogs[slot].alive = false
  let before = world.boss.hp
  world.runTicks(12 * 6 + 2)
  let dealt = before - world.boss.hp
  checkEq(dealt mod TankAttackDamage, 0, "every tank hit is 12")
  check(dealt >= TankAttackDamage * 5,
    "a tank in melee lands about one hit every 12 ticks (got " & $dealt & ")")
  checkEq(world.cogs[0].threat, dealt * TankThreatMul,
    "the tank's threat is three times its damage")
  done("tank auto-attack and threat multiplier")

proc testOutOfRangeAndThroughAPillar() =
  var world = quietWorld()
  ## Out of range: a dps 500 px from the boss cannot reach it.
  world.stand(2, PitCx, PitCy + 280)
  checkEq(world.canReach(2, PitCx, PitCy, DpsRange), true,
    "280 px is inside the 420 px dps range")
  ## Through a pillar: stand behind the south-east pillar on the diagonal.
  world.stand(2, 703 + 60, 415 + 60)
  checkEq(world.canReach(2, PitCx, PitCy, DpsRange), false,
    "a pillar between a dps and the boss blocks the attack")
  ## And a genuinely out-of-range shot.
  world.stand(3, PitCx - 250, PitCy)
  checkEq(world.canReach(3, PitCx + 250, PitCy, 400), false,
    "500 px apart is out of a 400 px reach")
  done("range and line of sight gate attacks")

proc testHealCast() =
  var world = quietWorld()
  let healer = world.healerSlot()
  world.stand(healer, PitCx, PitCy + 150)
  world.stand(0, PitCx, PitCy + 100)
  world.cogs[0].hp = 100
  world.setOrder(healer, Order(intent: inHealTarget, target: aliasOf(0),
    station: stPoint, px: world.cogs[healer].x, py: world.cogs[healer].y,
    hasPoint: true, onTelegraph: rxHold))
  world.holdStill(0)
  let mana = world.cogs[healer].mana
  world.runTicks(1)
  checkEq(world.cogs[healer].casting, ckHeal, "the cast starts on tick one")
  checkEq(world.cogs[healer].mana, mana - HealCost,
    "the cast costs 60 mana up front")
  world.runTicks(HealCastTicks - 1)
  check(world.cogs[0].hp == 100, "the heal has not landed a tick early")
  world.runTicks(1)
  checkEq(world.cogs[0].hp, 100 + HealAmount,
    "the heal completes at exactly 24 ticks for 90")
  done("heal cast length, cost and amount")

proc testHealCancelOnMovement() =
  var world = quietWorld()
  let healer = world.healerSlot()
  world.stand(healer, PitCx, PitCy + 150)
  world.stand(0, PitCx, PitCy + 100)
  world.cogs[0].hp = 100
  world.cogs[healer].casting = ckHeal
  world.cogs[healer].castTicks = 4
  world.cogs[healer].castTarget = 0
  world.cogs[healer].castStartX = world.cogs[healer].x
  world.cogs[healer].castStartY = world.cogs[healer].y
  world.cogs[healer].mana = ManaMax - HealCost
  ## Nine pixels of drift is more than the eight the design allows.
  world.cogs[healer].x += 9
  world.tickTimers()
  checkEq(world.cogs[healer].casting, ckNone, "the cast is cancelled")
  checkEq(world.cogs[healer].mana, ManaMax, "and the mana is refunded")
  let record = world.firstEvent("heal")
  check(record != nil and record{"result"}.getStr() == "cancelled",
    "a cancelled cast is recorded")
  done("a heal cancels when the healer moves 9 px")

proc testHealCancelOnTargetDeath() =
  var world = quietWorld()
  let healer = world.healerSlot()
  world.cogs[healer].casting = ckHeal
  world.cogs[healer].castTicks = 4
  world.cogs[healer].castTarget = 3
  world.cogs[healer].castStartX = world.cogs[healer].x
  world.cogs[healer].castStartY = world.cogs[healer].y
  world.cogs[healer].mana = 100
  world.cogs[3].alive = false
  world.tick = 5   ## off the mana-regen beat, so the refund is the only change
  world.tickTimers()
  checkEq(world.cogs[healer].casting, ckNone,
    "a cast on a corpse is cancelled")
  checkEq(world.cogs[healer].mana, 160, "with the mana refunded")
  done("a heal cancels when its target dies")

proc testManaRegen() =
  var world = quietWorld()
  let healer = world.healerSlot()
  world.cogs[healer].mana = 0
  world.holdStill(healer)
  world.runTicks(24)
  checkEq(world.cogs[healer].mana, ManaRegenPerTick,
    "30 mana per 24 ticks")
  world.cogs[healer].mana = ManaMax - 10
  world.runTicks(48)
  checkEq(world.cogs[healer].mana, ManaMax, "and the pool caps at 1200")
  done("mana regenerates 30 a second and caps")

proc testShieldExpiresUnspent() =
  var world = quietWorld()
  world.cogs[0].shield = ShieldAbsorb
  world.cogs[0].shieldTicks = ShieldExpireTicks
  world.runTicks(ShieldExpireTicks - 1)
  check(world.cogs[0].shield > 0, "the shield is still up one tick early")
  world.runTicks(1)
  checkEq(world.cogs[0].shield, 0,
    "an unspent shield expires after 480 ticks")
  done("shields expire")

proc testMultiplierOrder() =
  var world = quietWorld()
  checkEq(world.damageMultiplied(100), 100, "base")
  world.boss.feed = true
  checkEq(world.damageMultiplied(100), 125, "feed alone")
  world.boss.spillStacks = 2
  checkEq(world.damageMultiplied(100), 175, "feed x spill")
  world.boss.enraged = true
  checkEq(world.damageMultiplied(100), 525, "feed x spill x enrage")
  world.boss.feed = false
  checkEq(world.damageMultiplied(100), 420, "spill x enrage")
  world.boss.spillStacks = 0
  checkEq(world.damageMultiplied(100), 300, "enrage alone")
  world.boss.spillStacks = 5
  checkEq(world.damageMultiplied(100), 600, "five spill stacks x enrage")
  done("damage multiplier order is base x feed x spill x enrage")

proc testDamageIsAttributed() =
  var world = quietWorld()
  world.damageBoss(3, 500)
  checkEq(world.cogs[3].damageToBoss, 500, "damage to the boss is attributed")
  checkEq(world.boss.hp, world.boss.maxHp - 500, "and lands")
  world.adds.add(Add(id: 1, x: PitCx, y: PitCy - 100, hp: AddHp, alive: true,
    target: -1))
  world.damageAdd(0, 4, 60)
  checkEq(world.cogs[4].damageToAdds, 60, "damage to adds is attributed")
  checkEq(world.adds[0].hp, AddHp - 60, "and lands")
  done("meters attribute damage")

proc testAddDeathNamesItsKiller() =
  ## `add_death.killer` used to be the empty string on every record. An add
  ## carries its last hitter the same way a cog does, so the feed and the
  ## replay can say who cleared the wave.
  var world = quietWorld()
  world.adds.add(Add(id: 1, x: PitCx, y: PitCy - 100, hp: AddHp, alive: true,
    target: -1))
  world.damageAdd(0, 2, AddHp - 1)
  checkEq(world.adds[0].killer, "", "a hit that does not kill names nobody")
  world.damageAdd(0, 4, 1)
  checkEq(world.adds[0].killer, aliasOf(4), "the LAST hitter is the killer")
  world.runTicks(1)
  let record = world.firstEvent("add_death")
  check(record != nil, "the add's death is evented")
  checkEq(record{"killer"}.getStr(), aliasOf(4),
    "and the event carries the alias, not an empty string")
  checkEq(record{"id"}.getStr(), addName(1), "for the add that died")
  done("add_death names the cog that landed the last hit")

proc testOverhealIsRecorded() =
  var world = quietWorld()
  world.cogs[0].hp = world.cogs[0].maxHp - 10
  let outcome = world.healCog(0, HealAmount)
  checkEq(outcome.healed, 10, "only the missing hit points are healed")
  checkEq(outcome.overheal, HealAmount - 10, "the rest is overheal")
  done("overheal is recorded and wasted")

when isMainModule:
  testShieldBeforeHp()
  testShieldExactlyCovers()
  testTankAutoAttack()
  testOutOfRangeAndThroughAPillar()
  testHealCast()
  testHealCancelOnMovement()
  testHealCancelOnTargetDeath()
  testManaRegen()
  testShieldExpiresUnspent()
  testMultiplierOrder()
  testDamageIsAttributed()
  testAddDeathNamesItsKiller()
  testOverhealIsRecorded()
  echo "test_combat: all combat checks passed"
