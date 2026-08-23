## The encounter driver: the turn loop that sits between the 0.2 Hz decision
## layer and the 24 Hz sim.
##
## It is deliberately separate from the websocket server so the whole loop -
## the one-batch-per-turn contract, the per-turn budget, the budget guard, the
## wall-clock stop and the fault path - is testable against a fake decider and
## a fake clock with no sockets involved.
##
## Every wait here is bounded. The order of the guards matters: settle early
## on the scripted layer rather than overrun, and only stop dead at
## `wallClockBudgetSeconds` if even that was not enough.

import std/[json]
import types, state, sim, baselines, labels, scoring

type
  Clock* = proc (): float {.closure.}
  Decider* = proc (sim: Sim, seats: seq[int]): seq[Decision] {.closure.}
  TurnHook* = proc (sim: Sim) {.closure.}

proc livingSeats*(sim: Sim): seq[int] =
  for slot, cog in sim.cogs:
    if cog.alive:
      result.add(slot)

proc scriptedDecisions*(sim: Sim, seats: seq[int],
    kinds: seq[ScriptKind]): seq[Decision] =
  for seat in seats:
    let kind = if seat < kinds.len and kinds[seat] != skNone: kinds[seat]
               else: skStalwart
    result.add(Decision(order: scriptedOrder(sim, seat, kind),
      source: osScripted))

proc noteFallback(sim: var Sim, seat: int, decision: Decision) =
  case decision.cause
  of fcTimeout: sim.cogs[seat].fbTimeout.inc
  of fcParse: sim.cogs[seat].fbParse.inc
  of fcTransport: sim.cogs[seat].fbTransport.inc
  of fcNoCreds: sim.cogs[seat].fbNoCreds.inc
  of fcBudget: sim.cogs[seat].fbBudget.inc
  of fcNone: discard
  if decision.cause != fcNone:
    sim.record("fallback", %*{
      "turn": sim.tick div sim.config.turnTicks, "seat": seat,
      "alias": aliasOf(seat), "attempt": max(1, decision.attempts),
      "cause": $decision.cause,
      "detail": runeCap(decision.detail, MaxDetailRunes)
    })

proc applyTurn*(sim: var Sim, seats: seq[int], decisions: seq[Decision]) =
  ## Spread the per-seat decisions over all five slots and install them.
  var orders = newSeq[Order](sim.cogs.len)
  var sources = newSeq[OrderSource](sim.cogs.len)
  var latencies = newSeq[int](sim.cogs.len)
  for slot in 0 ..< sim.cogs.len:
    orders[slot] = sim.orders[slot]
    sources[slot] = sim.orderSources[slot]
  for index, seat in seats:
    if index >= decisions.len:
      continue
    orders[seat] = decisions[index].order
    sources[seat] = decisions[index].source
    latencies[seat] = decisions[index].latencyMs
  sim.installOrders(orders, sources, latencies)
  for index, seat in seats:
    if index < decisions.len:
      sim.noteFallback(seat, decisions[index])

proc runEncounter*(sim: var Sim, decide: Decider, now: Clock,
    kinds: seq[ScriptKind] = @[], onTurn: TurnHook = nil) =
  ## Drives the encounter to an end condition. `decide` is called at most once
  ## per turn, with every living seat in one call, so a simultaneous-decision
  ## game can batch them.
  let started = now()
  var guarded = false
  sim.encounterStart()
  while not sim.done:
    if sim.turnBoundary():
      let seats = livingSeats(sim)
      if seats.len == 0:
        sim.finish("complete", "wipe")
        break
      var decisions: seq[Decision]
      let elapsed = now() - started
      ## Budget guard: settle early on the scripted layer rather than
      ## overrun, so the episode ends complete/* instead of deadline/*.
      if not guarded and
          elapsed + 2.0 * sim.config.turnBudgetSeconds >
            sim.config.wallClockBudgetSeconds:
        guarded = true
        sim.record("budget_guard", %*{
          "turn": sim.tick div sim.config.turnTicks,
          "remaining_s": sim.config.wallClockBudgetSeconds - elapsed
        })
      if guarded:
        decisions = scriptedDecisions(sim, seats, kinds)
        for i in 0 ..< decisions.len:
          decisions[i].source = osFallback
          decisions[i].cause = fcBudget
      else:
        decisions = decide(sim, seats)
      sim.applyTurn(seats, decisions)
      if onTurn != nil:
        onTurn(sim)
    if sim.tick mod TargetFps == 0 and
        now() - started > sim.config.wallClockBudgetSeconds:
      ## The engine hard stop. Arithmetically unreachable once the budget
      ## guard has engaged, but the check is unconditional.
      sim.finish("deadline", "wall_clock")
      break
    try:
      sim.stepOnce()
    except CatchableError as error:
      sim.faultDetail = runeCap(error.msg, MaxDetailRunes)
      echo "raid: host error during the step: ", error.msg
      sim.finish("fault", "host_error")
      break
  var meters = newJArray()
  for cog in sim.cogs:
    meters.add(%*{
      "alias": aliasOf(cog.slot), "damage_to_boss": cog.damageToBoss,
      "damage_to_adds": cog.damageToAdds, "healing_done": cog.healingDone,
      "damage_taken": cog.damageTaken, "avoidable_hits": cog.avoidableHits
    })
  let enrage = sim.config.enrageTicks.float / TargetFps.float
  sim.record("end", %*{
    "reason": sim.reason, "end_rule": sim.endRule,
    "boss_hp_removed_frac":
      (sim.boss.maxHp - max(0, sim.boss.hp)).float /
        max(1, sim.boss.maxHp).float,
    "elapsed_s": sim.elapsedSeconds(),
    "charged_s": chargedSeconds(sim.endRule, enrage, sim.elapsedSeconds()),
    "score": sim.simScore(),
    "phase_reached": sim.boss.phase,
    "alive_at_end": sim.aliveCount(),
    "meters": meters
  })
