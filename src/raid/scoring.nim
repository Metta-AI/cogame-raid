## Scoring and the results document.
##
## The idea's pin, with the denominator closed the only way that keeps the
## game cooperative: a KILL is charged the seconds it actually took, and every
## other ending is charged the full enrage timer, because the raid consumed
## the whole attempt. Higher is better; 1.0 means "killed it exactly on the
## enrage timer".

import std/[json]
import types, state, labels

const ScoreCeiling* = 3.0

proc chargedSeconds*(endRule: string, enrageSeconds, elapsedSeconds: float):
    float =
  if endRule == "kill": elapsedSeconds else: enrageSeconds

proc episodeScore*(bossMaxHp, bossHpFinal, enrageTicks, finalTick: int,
    endRule: string): float =
  if bossMaxHp <= 0:
    return 0.0
  let removed = bossMaxHp - max(0, bossHpFinal)
  let fraction = removed.float / bossMaxHp.float
  let enrage = enrageTicks.float / TargetFps.float
  let elapsed = finalTick.float / TargetFps.float
  let charged = chargedSeconds(endRule, enrage, elapsed)
  if charged <= 0.0:
    return 0.0
  clamp(fraction * enrage / charged, 0.0, ScoreCeiling)

proc simScore*(sim: Sim): float =
  episodeScore(sim.boss.maxHp, sim.boss.hp, sim.config.enrageTicks,
    sim.tick, sim.endRule)

proc resultsJson*(sim: Sim): JsonNode =
  ## The closed schema in the design note, key for key. Adding or removing a
  ## key here means editing coworld_manifest_template.json's results_schema
  ## and tools/ci/docker_smoke.sh's expectations in the same commit.
  let score = sim.simScore()
  let removed = sim.boss.maxHp - max(0, sim.boss.hp)
  let elapsed = sim.tick.float / TargetFps.float
  let enrage = sim.config.enrageTicks.float / TargetFps.float
  var names = newJArray()
  var aliases = newJArray()
  var roles = newJArray()
  var kinds = newJArray()
  var scores = newJArray()
  var damageToBoss = newJArray()
  var damageToAdds = newJArray()
  var healingDone = newJArray()
  var overhealing = newJArray()
  var damageTaken = newJArray()
  var avoidable = newJArray()
  var interruptsLanded = newJArray()
  var interruptsWasted = newJArray()
  var llmTurns = newJArray()
  var fallbackTurns = newJArray()
  var fallbackCauses = newJArray()
  for slot, cog in sim.cogs:
    names.add(%sim.names[slot])
    aliases.add(%aliasOf(slot))
    roles.add(%($cog.role))
    kinds.add(%sim.policyKinds[slot])
    scores.add(%score)
    damageToBoss.add(%cog.damageToBoss)
    damageToAdds.add(%cog.damageToAdds)
    healingDone.add(%cog.healingDone)
    overhealing.add(%cog.overhealing)
    damageTaken.add(%cog.damageTaken)
    avoidable.add(%cog.avoidableHits)
    interruptsLanded.add(%cog.interruptsLanded)
    interruptsWasted.add(%cog.interruptsWasted)
    llmTurns.add(%cog.llmTurns)
    fallbackTurns.add(%cog.fallbackTurns)
    fallbackCauses.add(%*{
      "timeout": cog.fbTimeout, "parse_error": cog.fbParse,
      "transport_error": cog.fbTransport, "no_credentials": cog.fbNoCreds,
      "budget_guard": cog.fbBudget
    })
  %*{
    "names": names,
    "aliases": aliases,
    "roles": roles,
    "policy_kinds": kinds,
    "scores": scores,
    "boss_hp_removed": removed,
    "boss_max_hp": sim.boss.maxHp,
    "boss_hp_removed_frac": removed.float / max(1, sim.boss.maxHp).float,
    "elapsed_seconds": elapsed,
    "charged_seconds": chargedSeconds(sim.endRule, enrage, elapsed),
    "enrage_seconds": enrage,
    "phase_reached": sim.boss.phase,
    "kill": sim.endRule == "kill",
    "wipe": sim.endRule == "wipe",
    "deaths": sim.deaths,
    "alive_at_end": sim.aliveCount(),
    "damage_to_boss": damageToBoss,
    "damage_to_adds": damageToAdds,
    "healing_done": healingDone,
    "overhealing": overhealing,
    "damage_taken": damageTaken,
    "avoidable_hits": avoidable,
    "interrupts_landed": interruptsLanded,
    "interrupts_wasted": interruptsWasted,
    "overloads_resolved": sim.overloadsResolved,
    "adds_killed": sim.addsKilled,
    "spill_stacks": sim.boss.spillStacks,
    "reason": sim.reason,
    "end_rule": sim.endRule,
    "final_tick": sim.tick,
    "final_turn": sim.turn,
    "seed": sim.config.seed,
    "llm_turns": llmTurns,
    "fallback_turns": fallbackTurns,
    "fallback_causes": fallbackCauses
  }

proc resultsKeys*(): seq[string] =
  ## The closed key set, for the manifest test.
  @["names", "aliases", "roles", "policy_kinds", "scores", "boss_hp_removed",
    "boss_max_hp", "boss_hp_removed_frac", "elapsed_seconds",
    "charged_seconds", "enrage_seconds", "phase_reached", "kill", "wipe",
    "deaths", "alive_at_end", "damage_to_boss", "damage_to_adds",
    "healing_done", "overhealing", "damage_taken", "avoidable_hits",
    "interrupts_landed", "interrupts_wasted", "overloads_resolved",
    "adds_killed", "spill_stacks", "reason", "end_rule", "final_tick",
    "final_turn", "seed", "llm_turns", "fallback_turns", "fallback_causes"]
