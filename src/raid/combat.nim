## The damage funnel. Every subtraction in the encounter goes through
## `damageCog`, which spends the absorb shield before hit points exactly the
## way paintbot's `absorbDamage` does, and every point dealt to the boss goes
## through `damageBoss`, which is also where threat is accrued.

import std/[json]
import types, state, labels

proc damageCog*(sim: var Sim, slot, amount: int, ability, killer: string):
    tuple[absorbed, dealt: int] =
  ## Applies one damage instance to a cog. Shield first, then hp; the cog is
  ## left at or below zero and step 15 of the tick turns that into a death.
  if slot < 0 or slot >= sim.cogs.len or amount <= 0:
    return (0, 0)
  if not sim.cogs[slot].alive:
    return (0, 0)
  var absorbed = 0
  var remaining = amount
  if sim.cogs[slot].shield > 0:
    absorbed = min(sim.cogs[slot].shield, remaining)
    sim.cogs[slot].shield -= absorbed
    remaining -= absorbed
    if sim.cogs[slot].shield <= 0:
      sim.cogs[slot].shield = 0
      sim.cogs[slot].shieldTicks = 0
  sim.cogs[slot].hp -= remaining
  sim.cogs[slot].damageTaken += amount
  if sim.cogs[slot].hp <= 0:
    sim.cogs[slot].killer = killer
  ## Auto-attacks and pool ticks would be ~1500 records a minute and would
  ## drown the feed; they ride in the per-second keyframe meters instead.
  if amount >= 40:
    sim.record("boss_hit", %*{
      "target": aliasOf(slot), "ability": ability, "amount": amount,
      "absorbed": absorbed, "hp_left": max(0, sim.cogs[slot].hp)
    })
  (absorbed, remaining)

proc healCog*(sim: var Sim, slot, amount: int): tuple[healed, overheal: int] =
  if slot < 0 or slot >= sim.cogs.len or amount <= 0:
    return (0, 0)
  if not sim.cogs[slot].alive:
    return (0, amount)
  let room = sim.cogs[slot].maxHp - sim.cogs[slot].hp
  let healed = min(room, amount)
  sim.cogs[slot].hp += healed
  (healed, amount - healed)

proc damageBoss*(sim: var Sim, slot, amount: int) =
  ## One hit on SMELTER-9 from a cog. Threat is the damage times the role's
  ## multiplier; the tank's x3 is what makes holding aggro possible at all.
  if amount <= 0 or sim.boss.hp <= 0:
    return
  let before = sim.boss.hp
  sim.boss.hp = max(0, sim.boss.hp - amount)
  let dealt = before - sim.boss.hp
  if slot >= 0:
    sim.cogs[slot].damageToBoss += dealt
    let mult = if sim.cogs[slot].role == roleTank: TankThreatMul else: 1
    sim.cogs[slot].threat += dealt * mult
  ## One record per 5 % of the boss's health, so the feed can pace the burn
  ## without a record per shot.
  let bucketBefore = before * 20 div max(1, sim.boss.maxHp)
  let bucketAfter = sim.boss.hp * 20 div max(1, sim.boss.maxHp)
  if bucketAfter != bucketBefore and slot >= 0:
    sim.record("boss_damaged", %*{
      "seat": slot, "alias": aliasOf(slot), "amount": dealt,
      "boss_hp": sim.boss.hp, "boss_hp_pct": sim.bossHpPct()
    })

proc damageAdd*(sim: var Sim, index, slot, amount: int) =
  if index < 0 or index >= sim.adds.len or amount <= 0:
    return
  if not sim.adds[index].alive:
    return
  let before = sim.adds[index].hp
  sim.adds[index].hp = max(0, before - amount)
  if slot >= 0:
    sim.cogs[slot].damageToAdds += before - sim.adds[index].hp

proc healBoss*(sim: var Sim, amount: int) =
  sim.boss.hp = min(sim.boss.maxHp, sim.boss.hp + amount)

proc addThreatFromHealing*(sim: var Sim, slot, healed: int) =
  ## 0.25 threat per hp actually healed, kept integral by charging a quarter
  ## of the healed amount.
  if slot >= 0 and healed > 0:
    sim.cogs[slot].threat += healed div 4
