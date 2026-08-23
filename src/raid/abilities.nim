## Player abilities: taunt, heal, shield, interrupt and the auto-attack, plus
## the healer's mana pool. The fixed sub-order inside a tick (interrupt,
## taunt, shield, heal completion, attacks) is what makes races decidable.

import std/[json]
import types, state, arena, combat, labels

const
  ActAttack* = 1
  ActTaunt* = 2
  ActHeal* = 4
  ActShield* = 8
  ActInterrupt* = 16

proc hasBit*(action, bit: int): bool {.inline.} =
  (action and bit) != 0

proc canReach*(sim: Sim, slot, x, y, reach: int): bool =
  ## In range AND line-of-sight clear. Pillars block ranged attacks, heals and
  ## interrupts; hiding behind one stops you being healed, which is the point.
  if not withinPx(sim.cogs[slot].x, sim.cogs[slot].y, x, y, reach):
    return false
  sim.arena.lineOfSightClear(sim.cogs[slot].x, sim.cogs[slot].y, x, y)

proc cancelHeal*(sim: var Sim, slot: int, why: string) =
  if sim.cogs[slot].casting != ckHeal:
    return
  sim.cogs[slot].casting = ckNone
  sim.cogs[slot].castTicks = 0
  sim.cogs[slot].mana = min(ManaMax, sim.cogs[slot].mana + HealCost)
  let target = sim.cogs[slot].castTarget
  sim.cogs[slot].castTarget = -1
  sim.record("heal", %*{
    "seat": slot, "alias": aliasOf(slot),
    "target": (if target >= 0: aliasOf(target) else: ""),
    "amount": 0, "overheal": 0, "mana_left": sim.cogs[slot].mana,
    "result": "cancelled", "why": why
  })

proc tickTimers*(sim: var Sim) =
  ## Step 7: cooldowns down, casts up, shields age, mana regenerates.
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].attackCd > 0: sim.cogs[slot].attackCd.dec
    if sim.cogs[slot].tauntCd > 0: sim.cogs[slot].tauntCd.dec
    if sim.cogs[slot].shieldCd > 0: sim.cogs[slot].shieldCd.dec
    if sim.cogs[slot].interruptCd > 0: sim.cogs[slot].interruptCd.dec
    if sim.cogs[slot].shieldTicks > 0:
      sim.cogs[slot].shieldTicks.dec
      if sim.cogs[slot].shieldTicks == 0:
        sim.cogs[slot].shield = 0
    if not sim.cogs[slot].alive:
      continue
    if sim.cogs[slot].casting == ckHeal:
      ## A cast dies if the healer walks out of it, the target dies, or a
      ## pillar comes between them.
      let target = sim.cogs[slot].castTarget
      let drift = distSq(sim.cogs[slot].x, sim.cogs[slot].y,
        sim.cogs[slot].castStartX, sim.cogs[slot].castStartY)
      if drift > HealMoveCancelPx * HealMoveCancelPx:
        sim.cancelHeal(slot, "moved")
      elif target < 0 or not sim.cogs[target].alive:
        sim.cancelHeal(slot, "target_lost")
      elif not sim.canReach(slot, sim.cogs[target].x, sim.cogs[target].y,
          HealRange):
        sim.cancelHeal(slot, "line_of_sight")
      else:
        sim.cogs[slot].castTicks.inc
    if sim.cogs[slot].role == roleHealer and sim.tick mod TargetFps == 0:
      sim.cogs[slot].mana = min(ManaMax,
        sim.cogs[slot].mana + ManaRegenPerTick)
  for i in 0 ..< sim.telegraphs.len:
    if sim.telegraphs[i].fuse > 0:
      sim.telegraphs[i].fuse.dec
  if sim.boss.casting != bcNone and sim.boss.castTicks > 0:
    sim.boss.castTicks.dec

proc doInterrupts*(sim: var Sim, control: openArray[ControlOut]) =
  ## Step 8(a). If two interrupts land on one cast in one tick the LOWER slot
  ## wins and the other burns its cooldown for nothing.
  var landed = false
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive or not hasBit(control[slot].action, ActInterrupt):
      continue
    if sim.cogs[slot].role != roleDps or sim.cogs[slot].interruptCd > 0:
      continue
    if not sim.canReach(slot, sim.boss.x, sim.boss.y, InterruptRange):
      sim.record("interrupt", %*{
        "seat": slot, "alias": aliasOf(slot), "ability": $sim.boss.casting,
        "result": "out_of_range"
      })
      continue
    sim.cogs[slot].interruptCd = InterruptCooldownTicks
    if sim.boss.casting == bcNone:
      sim.cogs[slot].interruptsWasted.inc
      sim.record("interrupt", %*{
        "seat": slot, "alias": aliasOf(slot), "ability": "none",
        "result": "late"
      })
    elif landed:
      sim.cogs[slot].interruptsWasted.inc
      sim.record("interrupt", %*{
        "seat": slot, "alias": aliasOf(slot), "ability": "overload",
        "result": "wasted"
      })
    else:
      landed = true
      sim.cogs[slot].interruptsLanded.inc
      sim.record("interrupt", %*{
        "seat": slot, "alias": aliasOf(slot), "ability": "overload",
        "result": "success"
      })
      sim.boss.casting = bcNone
      sim.boss.castTicks = 0
      sim.boss.castTotal = 0
      sim.boss.overloadCd = OverloadCadence

proc doTaunts*(sim: var Sim, control: openArray[ControlOut]) =
  ## Step 8(b).
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive or not hasBit(control[slot].action, ActTaunt):
      continue
    if sim.cogs[slot].role != roleTank or sim.cogs[slot].tauntCd > 0:
      continue
    if not withinPx(sim.cogs[slot].x, sim.cogs[slot].y, sim.boss.x,
        sim.boss.y, TauntRange):
      sim.record("taunt", %*{
        "seat": slot, "alias": aliasOf(slot), "result": "out_of_range"
      })
      continue
    sim.cogs[slot].tauntCd = TauntCooldownTicks
    let already = sim.boss.target == slot
    var highest = 0
    for cog in sim.cogs:
      if cog.alive and cog.threat > highest:
        highest = cog.threat
    sim.cogs[slot].threat = max(sim.cogs[slot].threat, highest * 115 div 100)
    sim.boss.target = slot
    sim.boss.tauntLock = TauntLockTicks
    sim.record("taunt", %*{
      "seat": slot, "alias": aliasOf(slot),
      "result": (if already: "already_target" else: "pulled")
    })

proc doShields*(sim: var Sim, control: openArray[ControlOut]) =
  ## Step 8(c).
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive or not hasBit(control[slot].action, ActShield):
      continue
    if sim.cogs[slot].role != roleHealer or sim.cogs[slot].shieldCd > 0:
      continue
    if sim.cogs[slot].mana < ShieldCost:
      continue
    let target = control[slot].shieldTarget
    if target < 0 or target >= sim.cogs.len or not sim.cogs[target].alive:
      continue
    if not sim.canReach(slot, sim.cogs[target].x, sim.cogs[target].y,
        ShieldRange):
      continue
    sim.cogs[slot].mana -= ShieldCost
    sim.cogs[slot].shieldCd = ShieldCooldownTicks
    sim.cogs[target].shield = ShieldAbsorb
    sim.cogs[target].shieldTicks = ShieldExpireTicks
    sim.record("shield", %*{
      "seat": slot, "alias": aliasOf(slot), "target": aliasOf(target),
      "absorb": ShieldAbsorb
    })

proc completeHeals*(sim: var Sim) =
  ## Step 8(d): a cast that reached its full length applies now.
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive or sim.cogs[slot].casting != ckHeal:
      continue
    if sim.cogs[slot].castTicks < HealCastTicks:
      continue
    let target = sim.cogs[slot].castTarget
    sim.cogs[slot].casting = ckNone
    sim.cogs[slot].castTicks = 0
    sim.cogs[slot].castTarget = -1
    if target < 0 or target >= sim.cogs.len or not sim.cogs[target].alive:
      continue
    let outcome = sim.healCog(target, HealAmount)
    sim.cogs[slot].healingDone += outcome.healed
    sim.cogs[slot].overhealing += outcome.overheal
    sim.addThreatFromHealing(slot, outcome.healed)
    sim.record("heal", %*{
      "seat": slot, "alias": aliasOf(slot), "target": aliasOf(target),
      "amount": outcome.healed, "overheal": outcome.overheal,
      "mana_left": sim.cogs[slot].mana, "result": "applied"
    })

proc startHeals*(sim: var Sim, control: openArray[ControlOut]) =
  ## Casting begins at the END of the tick's ability block, so a cast started
  ## now first ticks on the next tick and lands exactly HealCastTicks later.
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive or not hasBit(control[slot].action, ActHeal):
      continue
    if sim.cogs[slot].role != roleHealer or sim.cogs[slot].casting != ckNone:
      continue
    if sim.cogs[slot].mana < HealCost:
      continue
    let target = control[slot].healTarget
    if target < 0 or target >= sim.cogs.len or not sim.cogs[target].alive:
      continue
    if not sim.canReach(slot, sim.cogs[target].x, sim.cogs[target].y,
        HealRange):
      continue
    sim.cogs[slot].mana -= HealCost
    sim.cogs[slot].casting = ckHeal
    sim.cogs[slot].castTicks = 0
    sim.cogs[slot].castTarget = target
    sim.cogs[slot].castStartX = sim.cogs[slot].x
    sim.cogs[slot].castStartY = sim.cogs[slot].y

proc doAttacks*(sim: var Sim, control: openArray[ControlOut]) =
  ## Step 8(e), in slot order.
  for slot in 0 ..< sim.cogs.len:
    sim.cogs[slot].attacking = ""
    if not sim.cogs[slot].alive:
      continue
    let kind = control[slot].attackKind
    if kind == atBoss:
      sim.cogs[slot].attacking = "boss"
    elif kind == atAdd and control[slot].attackAdd >= 0 and
        control[slot].attackAdd < sim.adds.len:
      sim.cogs[slot].attacking = addName(sim.adds[control[slot].attackAdd].id)
    if not hasBit(control[slot].action, ActAttack):
      continue
    if sim.cogs[slot].attackCd > 0 or sim.cogs[slot].casting != ckNone:
      continue
    let reach = roleRange(sim.cogs[slot].role)
    let damage = roleAttackDamage(sim.cogs[slot].role)
    case kind
    of atBoss:
      if sim.boss.hp <= 0:
        continue
      if not sim.canReach(slot, sim.boss.x, sim.boss.y, reach):
        continue
      sim.cogs[slot].attackCd = roleAttackCd(sim.cogs[slot].role)
      sim.damageBoss(slot, damage)
    of atAdd:
      let index = control[slot].attackAdd
      if index < 0 or index >= sim.adds.len or not sim.adds[index].alive:
        continue
      if not sim.canReach(slot, sim.adds[index].x, sim.adds[index].y, reach):
        continue
      sim.cogs[slot].attackCd = roleAttackCd(sim.cogs[slot].role)
      sim.damageAdd(index, slot, damage)
    of atNone:
      discard
