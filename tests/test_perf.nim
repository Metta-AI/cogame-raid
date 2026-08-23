## Performance: a full 6480-tick encounter with five cogs, the boss and a full
## house of crawlers has to be cheap, because the wall-clock budget belongs to
## the LLM, not to the physics.

import std/[times]
import support/helpers
import raid/[boss]

proc testFullEncounterIsCheap() =
  ## The generous bound the design note names: 30 s. In practice a release
  ## build is two orders of magnitude under it.
  let started = epochTime()
  let world = runScripted(testConfig(), skStalwart)
  let elapsed = epochTime() - started
  check(world.tick > 2000, "the encounter really ran (" & $world.tick & " ticks)")
  check(elapsed < 30.0,
    "a full encounter simulates in under 30 s (took " & $elapsed & " s)")
  echo "  full encounter: ", world.tick, " ticks in ",
    int(elapsed * 1000.0), " ms"
  done("a full encounter is cheap")

proc testWorstCaseLoad() =
  ## The heavy shape: eight crawlers alive, six pools down and a live
  ## telegraph, every tick, for the whole hard-stop length.
  var world = newWorld(testConfig())
  world.boss.phase = 2
  for wave in 0 ..< 4:
    world.boss.addsCd = 0
    world.updateAddWaves()
  checkEq(world.addsAlive(), AddCap, "eight crawlers up")
  for i in 0 ..< PoolCap:
    discard world.spawnPool(PitCx - 120 + i * 40, PitCy + 120, PourRadius)
  for slot in 0 ..< Seats:
    world.cogs[slot].hp = 100000
    world.cogs[slot].maxHp = 100000
  world.boss.hp = 100000000
  world.boss.maxHp = 100000000
  let started = epochTime()
  var ticks = 0
  while ticks < world.config.maxTicks and not world.done:
    if world.turnBoundary():
      let seats = livingSeats(world)
      world.applyTurn(seats, scriptedDecisions(world, seats,
        @[skStalwart, skStalwart, skStalwart, skStalwart, skStalwart]))
    world.stepOnce()
    ticks.inc
  let elapsed = epochTime() - started
  check(elapsed < 30.0,
    "6480 ticks with 5 cogs, the boss and 8 adds complete in under 30 s " &
    "(took " & $elapsed & " s)")
  echo "  worst case: ", ticks, " ticks in ", int(elapsed * 1000.0), " ms (",
    int(ticks.float / max(0.001, elapsed)), " ticks/s)"
  done("the worst-case load is comfortably inside the bound")

when isMainModule:
  testFullEncounterIsCheap()
  testWorstCaseLoad()
  echo "test_perf: the sim is fast enough that the budget belongs to the LLM"
