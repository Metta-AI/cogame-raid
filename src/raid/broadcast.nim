## The two views on the world.
##
## `seatView` is what a seat sees: aliases only, no seed, no other seat's
## private note, no prompt text, no real player name. It is both the `view`
## in the turn frame and the tail of the LLM user message.
##
## `globalSnapshot` is the spectator stream on `/global`: the same world plus
## the real policy names, the notes and the event transcript.

import std/[json]
import types, state, orders, labels, scoring, telegraphs, events

proc oneDecimal(value: float): float =
  ## Times are reported to one decimal so the prompt stays short and two
  ## identical states never differ by a float tail.
  float(int(value * 10.0 + (if value < 0.0: -0.5 else: 0.5))) / 10.0

proc ticksToSeconds(ticks: int): float =
  oneDecimal(ticks.float / TargetFps.float)

proc entityLabel(sim: Sim, slot: int): string =
  if slot < 0 or slot >= sim.cogs.len: "" else: aliasOf(slot)

proc cooldownsJson(sim: Sim, slot: int): JsonNode =
  result = newJObject()
  case sim.cogs[slot].role
  of roleTank:
    result["taunt"] = %ticksToSeconds(sim.cogs[slot].tauntCd)
  of roleHealer:
    result["heal"] = %0.0
    result["shield"] = %ticksToSeconds(sim.cogs[slot].shieldCd)
  of roleDps:
    result["interrupt"] = %ticksToSeconds(sim.cogs[slot].interruptCd)
  result["attack"] = %ticksToSeconds(sim.cogs[slot].attackCd)

proc telegraphJson(sim: Sim, tel: Telegraph, slot: int): JsonNode =
  result = %*{
    "id": tel.id, "kind": $tel.kind,
    "shape": (if tel.kind == tkCleave: "cone" else: "circle"),
    "resolves_in_s": ticksToSeconds(tel.fuse),
    "soak_needed": tel.soakNeeded,
    "you_are_inside": sim.telegraphContains(tel, sim.cogs[slot].x,
      sim.cogs[slot].y)
  }
  if tel.kind == tkCleave:
    result["centre"] = %*[sim.boss.x, sim.boss.y]
    result["facing_brads"] = %tel.facing
    result["half_angle_brads"] = %tel.halfBrads
    result["reach"] = %tel.reach
  else:
    result["centre"] = %*[tel.cx, tel.cy]
    result["radius"] = %tel.radius

proc bossNextJson(sim: Sim): JsonNode =
  ## The boss's schedule is deterministic and published in docs/RULES.md, so
  ## hiding it would reward memorisation, not play.
  %*{
    "cleave": ticksToSeconds(max(0, sim.boss.cleaveCd)),
    "pour": ticksToSeconds(max(0, sim.boss.pourCd)),
    "overload": ticksToSeconds(max(0, sim.boss.overloadCd)),
    "adds": ticksToSeconds(max(0, sim.boss.addsCd))
  }

proc seatView*(sim: Sim, slot: int): JsonNode =
  ## Everything visible to one seat, and nothing else.
  var raid = newJArray()
  for i, cog in sim.cogs:
    raid.add(%*{
      "alias": aliasOf(i), "role": $cog.role, "pos": [cog.x, cog.y],
      "alive": cog.alive, "hp": max(0, cog.hp), "max_hp": cog.maxHp,
      "shield": cog.shield, "threat": cog.threat,
      "attacking": cog.attacking,
      "last_intent": $sim.orders[i].intent,
      "say": sim.says[i]
    })
  var adds = newJArray()
  for a in sim.adds:
    if a.alive:
      adds.add(%*{
        "id": addName(a.id), "pos": [a.x, a.y], "hp": a.hp,
        "max_hp": AddHp, "target": entityLabel(sim, a.target)
      })
  var pools = newJArray()
  for pool in sim.pools:
    pools.add(%*{
      "id": pool.id, "centre": [pool.cx, pool.cy], "radius": pool.radius,
      "expires_in_s": ticksToSeconds(
        max(0, PoolTicks - (sim.tick - pool.spawnTick)))
    })
  var telegraphs = newJArray()
  for tel in sim.telegraphs:
    telegraphs.add(telegraphJson(sim, tel, slot))
  var callouts = newJArray()
  for i in 0 ..< sim.cogs.len:
    if i != slot and sim.says[i].len > 0:
      callouts.add(%*{"alias": aliasOf(i), "say": sim.says[i]})
  var damageToBoss = newJArray()
  var healingDone = newJArray()
  for cog in sim.cogs:
    damageToBoss.add(%cog.damageToBoss)
    healingDone.add(%cog.healingDone)
  var you = %*{
    "alias": aliasOf(slot), "role": $sim.cogs[slot].role,
    "pos": [sim.cogs[slot].x, sim.cogs[slot].y],
    "alive": sim.cogs[slot].alive, "hp": max(0, sim.cogs[slot].hp),
    "max_hp": sim.cogs[slot].maxHp, "shield": sim.cogs[slot].shield,
    "threat": sim.cogs[slot].threat,
    "attacking": sim.cogs[slot].attacking,
    "cooldowns_s": cooldownsJson(sim, slot)
  }
  if sim.cogs[slot].role == roleHealer:
    you["mana"] = %sim.cogs[slot].mana
    you["max_mana"] = %ManaMax
  if sim.cogs[slot].casting != ckNone:
    you["casting"] = %*{
      "ability": $sim.cogs[slot].casting,
      "target": entityLabel(sim, sim.cogs[slot].castTarget),
      "remaining_s": ticksToSeconds(
        max(0, HealCastTicks - sim.cogs[slot].castTicks))
    }
  var boss = %*{
    "name": BossName, "pos": [sim.boss.x, sim.boss.y],
    "facing_brads": sim.boss.aim, "hp": max(0, sim.boss.hp),
    "max_hp": sim.boss.maxHp, "hp_pct": oneDecimal(sim.bossHpPct()),
    "phase": sim.boss.phase, "target": entityLabel(sim, sim.boss.target),
    "enraged": sim.boss.enraged,
    "buffs": {"feed": sim.boss.feed, "spill_stacks": sim.boss.spillStacks},
    "next_s": bossNextJson(sim)
  }
  if sim.boss.casting != bcNone:
    boss["casting"] = %*{
      "ability": $sim.boss.casting,
      "remaining_s": ticksToSeconds(sim.boss.castTicks),
      "interruptible": true
    }
  result = %*{
    "turn": sim.turn,
    "of": (sim.config.maxTicks + sim.config.turnTicks - 1) div
      sim.config.turnTicks,
    "tick": sim.tick, "phase": sim.boss.phase,
    "phase_name": phaseName(sim.boss.phase),
    "clock": {
      "elapsed_s": ticksToSeconds(sim.tick),
      "enrage_in_s": ticksToSeconds(max(0, sim.config.enrageTicks - sim.tick)),
      "hard_end_in_s": ticksToSeconds(max(0, sim.config.maxTicks - sim.tick))
    },
    "you": you,
    "boss": boss,
    "telegraphs": telegraphs,
    "raid": raid,
    "adds": adds,
    "pools": pools,
    "callouts": callouts,
    "meters": {"damage_to_boss": damageToBoss, "healing_done": healingDone}
  }
  if sim.haveOrder[slot]:
    result["your_last_order"] = orderToJson(sim.orders[slot])
  else:
    result["your_last_order"] = newJNull()

proc globalSnapshot*(sim: Sim, connected: seq[bool]): JsonNode =
  ## The spectator stream. Real policy names appear HERE and in the replay,
  ## never in a seat's view.
  var seats = newJArray()
  for i, cog in sim.cogs:
    seats.add(%*{
      "slot": i, "alias": aliasOf(i), "name": sim.names[i],
      "policy_kind": sim.policyKinds[i], "role": $cog.role,
      "pos": [cog.x, cog.y], "aim": cog.aim, "alive": cog.alive,
      "hp": max(0, cog.hp), "max_hp": cog.maxHp, "shield": cog.shield,
      "mana": cog.mana, "threat": cog.threat, "attacking": cog.attacking,
      "intent": $sim.orders[i].intent, "note": sim.orders[i].note,
      "say": sim.says[i], "source": $sim.orderSources[i],
      "damage_to_boss": cog.damageToBoss, "healing_done": cog.healingDone,
      "damage_taken": cog.damageTaken, "avoidable_hits": cog.avoidableHits,
      "connected": (if i < connected.len: connected[i] else: false)
    })
  var adds = newJArray()
  for a in sim.adds:
    if a.alive:
      adds.add(%*{"id": addName(a.id), "pos": [a.x, a.y], "hp": a.hp})
  var pools = newJArray()
  for pool in sim.pools:
    pools.add(%*{"id": pool.id, "centre": [pool.cx, pool.cy],
      "radius": pool.radius, "age": sim.tick - pool.spawnTick})
  var telegraphs = newJArray()
  for tel in sim.telegraphs:
    telegraphs.add(%*{
      "id": tel.id, "kind": $tel.kind, "centre": [tel.cx, tel.cy],
      "radius": tel.radius, "facing_brads": tel.facing,
      "half_angle_brads": tel.halfBrads, "reach": tel.reach,
      "fuse": tel.fuse, "soak_needed": tel.soakNeeded
    })
  %*{
    "type": "state", "game": "raid", "protocol": "raid.global.v1",
    "tick": sim.tick, "turn": sim.turn,
    "ticks_per_second": TargetFps,
    "phase": sim.boss.phase, "phase_name": phaseName(sim.boss.phase),
    "seats": seats,
    "boss": {
      "name": BossName, "pos": [sim.boss.x, sim.boss.y],
      "aim": sim.boss.aim, "hp": max(0, sim.boss.hp),
      "max_hp": sim.boss.maxHp, "hp_pct": oneDecimal(sim.bossHpPct()),
      "target": entityLabel(sim, sim.boss.target),
      "enraged": sim.boss.enraged, "feed": sim.boss.feed,
      "spill_stacks": sim.boss.spillStacks,
      "casting": $sim.boss.casting,
      "cast_remaining": sim.boss.castTicks,
      "cast_total": sim.boss.castTotal
    },
    "adds": adds, "pools": pools, "telegraphs": telegraphs,
    "enrage_in_s": ticksToSeconds(max(0, sim.config.enrageTicks - sim.tick)),
    "hard_end_in_s": ticksToSeconds(max(0, sim.config.maxTicks - sim.tick)),
    "events": sim.events.toJson(),
    "done": sim.done, "reason": sim.reason, "end_rule": sim.endRule,
    "score": (if sim.done: sim.simScore() else: 0.0)
  }
