## Sim unit tests on movement: the analog step, friction, wall sliding,
## cog-cog resolution and the dodge budget the design note's MaxSpeed = 832 is
## derived from.

import std/[strutils]
import support/helpers

proc testTopSpeed() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy + 200)
  for i in 0 ..< 200:
    world.moveCog(0, 100, 0)
  checkEq(world.cogs[0].velX, MaxSpeed,
    "a cardinal full-throttle axis settles at exactly MaxSpeed")
  for i in 0 ..< 50:
    world.moveCog(0, 100, 0)
  checkEq(world.cogs[0].velX, MaxSpeed, "and never goes past it")
  done("top speed")

proc testDiagonalIsNotFaster() =
  var cardinal = quietWorld()
  cardinal.stand(0, PitCx - 200, PitCy)
  var diagonal = quietWorld()
  diagonal.stand(0, PitCx - 200, PitCy)
  for i in 0 ..< 60:
    cardinal.moveCog(0, 100, 0)
    diagonal.moveCog(0, 100, 100)
  check(diagonal.cogs[0].velX <= cardinal.cogs[0].velX,
    "a full diagonal is not faster than a cardinal on the x axis")
  check(diagonal.cogs[0].velY <= cardinal.cogs[0].velX,
    "a full diagonal is not faster than a cardinal on the y axis")
  done("diagonal is not faster")

proc testHalfThrottle() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy + 150)
  for i in 0 ..< 200:
    world.moveCog(0, 50, 0)
  checkEq(world.cogs[0].velX, MaxSpeed * 50 div 100,
    "half throttle clamps that axis to half MaxSpeed")
  done("analog throttle clamps per axis")

proc testFriction() =
  var world = quietWorld()
  world.stand(0, PitCx, PitCy + 150)
  for i in 0 ..< 60:
    world.moveCog(0, 100, 0)
  check(world.cogs[0].velX > 0, "moving before we let go")
  for i in 0 ..< 40:
    world.moveCog(0, 0, 0)
  checkEq(world.cogs[0].velX, 0,
    "an uncommanded axis is brought to rest below StopThreshold")
  done("friction")

proc testStaysInsideThePit() =
  ## 3000 ticks of input hammering the rim and the pillars, from a handful of
  ## headings; the wall slide must never let a body leave the disc.
  var world = quietWorld()
  let headings = [[100, 0], [-100, 0], [0, 100], [0, -100],
                  [100, 100], [-100, 100], [100, -100], [-100, -100]]
  for h in 0 ..< headings.len:
    world.stand(0, PitCx, PitCy + 120)
    for i in 0 ..< 375:
      world.moveCog(0, headings[h][0], headings[h][1])
      check(world.arena.canOccupyCog(world.cogs[0].x, world.cogs[0].y),
        "cog stayed on legal floor at heading " & $h & " tick " & $i)
      let dx = world.cogs[0].x - PitCx
      let dy = world.cogs[0].y - PitCy
      check(dx * dx + dy * dy <= PitRadius * PitRadius,
        "cog stayed inside the pit at heading " & $h)
  done("wall slide keeps the body inside the pit")

proc testBodiesResolveSymmetrically() =
  ## Swapping the slot indexes mirrors the outcome.
  var a = quietWorld()
  a.stand(0, PitCx - 4, PitCy + 150)
  a.stand(1, PitCx + 4, PitCy + 150)
  var b = quietWorld()
  b.stand(0, PitCx + 4, PitCy + 150)
  b.stand(1, PitCx - 4, PitCy + 150)
  for i in 0 ..< 40:
    a.moveCog(0, 100, 0)
    a.moveCog(1, -100, 0)
    b.moveCog(0, -100, 0)
    b.moveCog(1, 100, 0)
  checkEq(a.cogs[0].x - PitCx, PitCx - b.cogs[0].x,
    "slot 0 mirrors when the pair is swapped")
  checkEq(a.cogs[1].x - PitCx, PitCx - b.cogs[1].x,
    "slot 1 mirrors when the pair is swapped")
  done("cog-cog overlap resolves symmetrically")

proc testDodgeBudget() =
  ## The arithmetic MaxSpeed = 832 exists for: dodging a 90 px pour centred on
  ## your own feet needs 90 + 6 + 20 = 116 px inside a 60-tick fuse.
  var world = quietWorld()
  world.stand(0, PitCx - 100, PitCy + 200)
  let startX = world.cogs[0].x
  for i in 0 ..< 60:
    world.moveCog(0, 100, 0)
  let travelled = world.cogs[0].x - startX
  check(travelled >= 116,
    "a standing start clears 116 px inside 60 ticks (got " & $travelled & ")")
  done("dodge budget")

proc testDeadCogIsInert() =
  var world = quietWorld()
  world.cogs[2].alive = false
  let before = (world.cogs[2].x, world.cogs[2].y)
  world.runTicks(48)
  checkEq((world.cogs[2].x, world.cogs[2].y), before,
    "a dead cog is frozen in place as a wreck")
  done("dead cogs are inert")

when isMainModule:
  testTopSpeed()
  testDiagonalIsNotFaster()
  testHalfThrottle()
  testFriction()
  testStaysInsideThePit()
  testBodiesResolveSymmetrically()
  testDodgeBudget()
  testDeadCogIsInert()
  echo "test_motion: all motion checks passed"
