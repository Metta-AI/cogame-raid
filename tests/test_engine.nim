## The turn loop against a fake decider and a fake clock: the one-parallel-
## batch contract, the per-turn budget, the budget guard, the wall-clock stop
## and the fault path.

import std/[json, strutils, times]
import support/helpers

type
  Window = object
    seat, opened, closed: int

  FakeClient = ref object
    ## Records the in-flight window of every "request" it serves, so the test
    ## can assert they INTERSECT: a game that queried seats sequentially would
    ## produce disjoint windows and blow the play budget.
    clock: int
    windows: seq[Window]
    batches: seq[int]

proc decideAll(client: FakeClient, world: Sim, seats: seq[int]):
    seq[Decision] =
  client.batches.add(seats.len)
  let opened = client.clock
  ## Every seat's request is issued together and they all come back together;
  ## that is what `curly.makeRequests` does with one batch.
  for seat in seats:
    client.windows.add(Window(seat: seat, opened: opened,
      closed: opened + 1))
  client.clock.inc
  for seat in seats:
    result.add(Decision(order: scriptedOrder(world, seat, skStalwart),
      source: osLlm, latencyMs: 120, attempts: 1))

proc windowsIntersect(client: FakeClient, turn: int): bool =
  var opened = -1
  var closed = -1
  for window in client.windows:
    if window.opened == turn:
      if opened < 0:
        opened = window.opened
        closed = window.closed
      if window.opened >= closed or window.closed <= opened:
        return false
  opened >= 0

proc testOneParallelBatchPerTurn() =
  var world = newWorld(certConfig())
  let client = FakeClient()
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    client.decideAll(view, seats)
  let clock: Clock = proc (): float = 0.0
  runEncounter(world, decide, clock, @[], nil)
  check(client.batches.len > 3, "several turns happened")
  for turn in 0 ..< client.batches.len:
    check(windowsIntersect(client, turn),
      "every seat's request in turn " & $turn & " was in flight together")
  checkEq(client.batches[0], Seats, "a full turn batches five requests")
  done("all living seats go out as one parallel batch")

proc testDeadSeatsDropOutOfTheBatch() =
  var world = newWorld(certConfig())
  world.cogs[1].alive = false
  world.cogs[3].alive = false
  let seats = livingSeats(world)
  checkEq(seats.len, 3, "a turn with two dead cogs batches exactly 3")
  check(1 notin seats and 3 notin seats, "and never queries a corpse")
  done("dead seats are never queried")

proc testBudgetGuardSettlesEarly() =
  ## A clock that is already deep into the budget makes the guard engage on
  ## the first turn; the encounter finishes on the scripted layer and still
  ## ends `complete`.
  var world = newWorld(certConfig())
  var called = 0
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    called.inc
    for seat in seats:
      result.add(Decision(order: scriptedOrder(view, seat, skStalwart),
        source: osLlm))
  var calls = 0
  let clock: Clock = proc (): float =
    calls.inc
    if calls == 1: 0.0 else: 175.0
  runEncounter(world, decide, clock, @[], nil)
  checkEq(called, 0, "the LLM is skipped for every remaining turn")
  checkEq(world.reason, "complete",
    "and the episode still ends complete, not deadline")
  check(world.firstEvent("budget_guard") != nil,
    "with a budget_guard record naming the turn it engaged")
  for slot in 0 ..< Seats:
    check(world.cogs[slot].fbBudget > 0, "counted as a budget fallback")
  done("the budget guard settles the encounter early")

proc testWallClockStop() =
  ## A clock past the budget with the guard unable to help: the engine stops
  ## dead and reports deadline/wall_clock.
  var world = newWorld(certConfig())
  var ticking = 0.0
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    for seat in seats:
      result.add(Decision(order: scriptedOrder(view, seat, skStalwart),
        source: osScripted))
  let clock: Clock = proc (): float =
    ticking += 40.0
    ticking
  runEncounter(world, decide, clock, @[], nil)
  checkEq(world.reason, "deadline", "the engine hard stop fires")
  checkEq(world.endRule, "wall_clock", "with wall_clock")
  check(world.tick > 0, "after simulating something")
  check(world.tick < world.config.maxTicks, "and stopping short of the end")
  let results = resultsJson(world)
  checkEq(results["reason"].getStr(), "deadline", "reported in the results")
  check(results["scores"][0].getFloat() >= 0.0,
    "scored on the damage actually dealt")
  done("the 660 s stop yields deadline/wall_clock")

proc testSimFault() =
  ## A tripped invariant ends the episode `fault/sim_fault` with a partial
  ## replay and the damage-only score.
  var world = newWorld(certConfig())
  world.runTicks(120)
  world.boss.hp = world.boss.maxHp + 5000    ## boss hp above max: an invariant
  world.runTicks(1)
  checkEq(world.reason, "fault", "a broken invariant is a fault")
  checkEq(world.endRule, "sim_fault", "of the sim kind")
  check(world.faultDetail.len > 0, "with a description")
  check(world.keyframes.len > 0, "and a partial replay to look at")
  let results = resultsJson(world)
  checkEq(results["end_rule"].getStr(), "sim_fault", "reported")
  done("a tripped invariant yields fault/sim_fault")

proc testEveryTurnRecordsOrders() =
  var world = newWorld(certConfig())
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    for seat in seats:
      result.add(Decision(order: scriptedOrder(view, seat, skStalwart),
        source: osLlm, latencyMs: 90))
  let clock: Clock = proc (): float = 0.0
  runEncounter(world, decide, clock, @[], nil)
  let orders = world.eventsOf("order")
  let turns = world.eventsOf("turn_start")
  check(turns.len > 3, "several turns")
  check(orders.len >= turns.len * 3,
    "at least one order per living seat per turn")
  for record in orders:
    checkEq(record{"source"}.getStr(), "llm", "sourced as llm")
    check(record{"intent"}.getStr().len > 0, "with a real intent")
    check(record{"latency_ms"}.getInt() > 0, "and a latency")
  check(world.firstEvent("end") != nil, "and the encounter emits `end`")
  done("every turn records one order per living seat")

proc testEncounterEndsWithoutADecider() =
  ## The offline path: no credentials at all, every turn falls back instantly.
  let world = runScripted(certConfig(), skStalwart)
  checkEq(world.reason, "complete", "an offline episode completes")
  for record in world.eventsOf("order"):
    checkEq(record{"source"}.getStr(), "scripted", "on the scripted layer")
  done("with no LLM at all the encounter still completes")

proc testHungClientKeepsTheEpisodeInsideItsBudget() =
  ## A client that hangs answers only when its deadline expires, so every turn
  ## costs the whole budget: the effective attempt plus the effective retry.
  ## The episode still has to settle and score inside wallClockBudgetSeconds -
  ## the budget guard drops to the scripted layer before the wall clock can
  ## run out, and the encounter ends complete/*, never deadline/*.
  var world = newWorld(testConfig())     ## the default variant, 54 turns
  let perTurn = float(deadlineSeconds(world.config.llmAttemptSeconds) +
    deadlineSeconds(world.config.llmRetrySeconds))
  checkEq(perTurn, world.config.turnBudgetSeconds,
    "a hung turn costs the whole 10 s budget")
  var elapsed = 0.0
  var hungTurns = 0
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    ## Hangs to its deadline, then falls back, exactly as decideAll does when
    ## both attempts time out.
    hungTurns.inc
    elapsed += perTurn
    for seat in seats:
      result.add(Decision(order: scriptedOrder(view, seat, skStalwart),
        source: osFallback, attempts: 2, cause: fcTimeout,
        detail: "llm transport: Timeout was reached"))
  let clock: Clock = proc (): float = elapsed
  runEncounter(world, decide, clock, @[], nil)
  check(hungTurns > 0, "the hung client was actually queried")
  checkEq(world.reason, "complete",
    "the episode settles rather than hitting the wall-clock stop")
  check(elapsed <= world.config.wallClockBudgetSeconds,
    "inside the wall-clock budget (" & $elapsed & "s of " &
      $world.config.wallClockBudgetSeconds & "s)")
  check(hungTurns <= world.config.maxTicks div world.config.turnTicks,
    "having queried the client at most once per turn")
  checkEq(elapsed, float(hungTurns) * perTurn,
    "with every one of those turns costing the full deadline")
  let results = resultsJson(world)
  check(results["scores"][0].getFloat() >= 0.0, "and the episode is scored")
  done("a hung client cannot push the episode past its budget")

proc testEffectiveDeadlinesFitTheTurnBudget() =
  ## The LLM deadlines are handed to curl, whose timeout is WHOLE seconds, so
  ## the configured 6.5 s first attempt really waits 7 s. The budget check has
  ## to be made on those rounded numbers: 6.2 + 3.2 looks like 9.4 s and is
  ## really 7 + 4 = 11 s, a turn over its budget.
  checkEq(deadlineSeconds(6.5), 7, "6.5 s of deadline is 7 s of waiting")
  checkEq(deadlineSeconds(3.0), 3, "a whole number is itself")
  checkEq(deadlineSeconds(0.2), 1, "and nothing gets less than a second")
  var config = certConfig()
  config.validate()          ## 7 + 3 = exactly the 10.0 s budget: allowed
  config.llmAttemptSeconds = 6.2
  config.llmRetrySeconds = 3.2
  var raised = ""
  try:
    config.validate()
  except RaidError as error:
    raised = error.msg
  check(raised.len > 0, "a config that rounds up past the budget is refused")
  check("turnBudgetSeconds" in raised, "and says which bound it broke")
  done("the turn budget is checked against the deadlines curl actually uses")

when isMainModule:
  testOneParallelBatchPerTurn()
  testDeadSeatsDropOutOfTheBatch()
  testBudgetGuardSettlesEarly()
  testWallClockStop()
  testSimFault()
  testEveryTurnRecordsOrders()
  testEncounterEndsWithoutADecider()
  testHungClientKeepsTheEpisodeInsideItsBudget()
  testEffectiveDeadlinesFitTheTurnBudget()
  echo "test_engine: the turn loop, its budgets and its fault paths check out"
