## Telegraphs, and the Crucible Pour in particular.

import std/[json]
import support/helpers
import raid/[telegraphs, control, combat]

proc placeCrucible(world: var Sim, cx, cy: int) =
  world.telegraphs = @[Telegraph(
    id: world.nextTelegraphId, kind: tkCrucible, cx: cx, cy: cy,
    radius: CrucibleRadius, fuse: 0, soakNeeded: 1, drawnOn: -1)]
  world.nextTelegraphId.inc

proc parkEveryoneAwayFrom(world: var Sim, cx, cy: int) =
  for slot in 0 ..< Seats:
    world.stand(slot, PitCx - 250 + slot * 8, PitCy)
  discard cx
  discard cy

proc testCrucibleUnsoaked() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy + 200)
  world.placeCrucible(PitCx + 220, PitCy)
  world.resolveTelegraphs()
  checkEq(world.boss.spillStacks, 1, "nobody in it grants exactly one Spill")
  checkEq(world.pools.len, 0, "and leaves no pool")
  let record = world.firstEvent("telegraph_resolve")
  checkEq(record{"spill_gained"}.getInt(), 1, "recorded")
  done("k == 0 grants one Spill stack and leaves no pool")

proc testSpillCap() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy)
  for i in 0 ..< 9:
    world.placeCrucible(PitCx + 220, PitCy)
    world.resolveTelegraphs()
  checkEq(world.boss.spillStacks, SpillMaxStacks, "Spill caps at five")
  done("Spill stacks cap at five")

proc testCrucibleSplit() =
  for soakers in 1 .. 3:
    var world = quietWorld()
    world.parkEveryoneAwayFrom(PitCx, PitCy)
    let cx = PitCx + 200
    let cy = PitCy
    for i in 0 ..< soakers:
      world.stand(2 + i, cx + i * 14, cy)
      world.cogs[2 + i].hp = 1000
      world.cogs[2 + i].maxHp = 1000
    world.placeCrucible(cx, cy)
    world.resolveTelegraphs()
    let expected = CrucibleDamage div soakers
    for i in 0 ..< soakers:
      checkEq(1000 - world.cogs[2 + i].hp, expected,
        $soakers & " soakers each take " & $expected)
    checkEq(world.pools.len, 1, "and a pool is left")
  done("240 splits evenly: 240 alone, 120 for two, 80 for three")

proc testMembershipIsAtResolution() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy)
  let cx = PitCx + 200
  ## In the circle at cast time, gone by resolution.
  world.stand(2, cx, PitCy)
  world.telegraphs = @[Telegraph(id: 1, kind: tkCrucible, cx: cx, cy: PitCy,
    radius: CrucibleRadius, fuse: 4, soakNeeded: 1, drawnOn: 2)]
  world.stand(2, PitCx - 250, PitCy)
  world.telegraphs[0].fuse = 0
  world.resolveTelegraphs()
  checkEq(world.cogs[2].hp, world.cogs[2].maxHp,
    "membership is decided at the RESOLUTION tick, not at cast start")
  checkEq(world.boss.spillStacks, 1, "so nobody soaked it")
  done("membership is decided at the resolution tick")

proc testDeadCogDoesNotCount() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy)
  let cx = PitCx + 200
  world.stand(2, cx, PitCy)
  world.stand(3, cx + 10, PitCy)
  world.cogs[3].alive = false
  world.placeCrucible(cx, PitCy)
  world.resolveTelegraphs()
  checkEq(world.cogs[2].maxHp - world.cogs[2].hp, CrucibleDamage,
    "the corpse does not share the split")
  done("a cog that died mid-fuse is not counted")

proc testBodyCentreMembership() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy)
  let tel = Telegraph(id: 1, kind: tkPour, cx: PitCx + 200, cy: PitCy,
    radius: PourRadius, fuse: 0, drawnOn: -1)
  check(world.telegraphContains(tel, PitCx + 200 + PourRadius, PitCy),
    "exactly on the radius is inside")
  check(not world.telegraphContains(tel, PitCx + 201 + PourRadius, PitCy),
    "one pixel past it is not")
  done("circle membership is by body centre, inclusive at the radius")

proc testDodgeLeavesTheShape() =
  ## From a starting point inside a pour circle, the dodge reaction walks
  ## strictly outward and, on open floor, clears the shape inside the 60-tick
  ## fuse. It is NOT unconditional: there is no pathfinder, the pit is only
  ## 300 px across and four pillars sit at radius 150, so a cog whose outward
  ## line runs into a pillar or the rim gets what floor there is. The
  ## assertion is therefore the honest one - always outward, and clear from
  ## the overwhelming majority of starting points.
  var offsets: seq[(int, int)]
  for angle in countup(0, 255, 16):
    for dist in [0, 30, 60, 85]:
      offsets.add((BradX[angle] * dist div 1024, BradY[angle] * dist div 1024))
  var cleared = 0
  var total = 0
  for offset in offsets:
    var world = quietWorld()
    let cx = PitCx
    let cy = PitCy + 140
    world.stand(2, cx + offset[0], cy + offset[1])
    for slot in 0 ..< Seats:
      if slot != 2:
        world.stand(slot, PitCx - 260, PitCy - 20 + slot * 12)
    world.telegraphs = @[Telegraph(id: 1, kind: tkPour, cx: cx, cy: cy,
      radius: PourRadius, fuse: PourTelegraphTicks, soakNeeded: 0,
      drawnOn: 2)]
    world.setOrder(2, Order(intent: inBurnBoss, target: "boss",
      station: stRanged, onTelegraph: rxDodge))
    for i in 0 ..< PourTelegraphTicks:
      world.telegraphs[0].fuse = PourTelegraphTicks - i
      let control = compileControl(world, 2, i == 0)
      world.moveCog(2, control.moveX, control.moveY)
    let dx = world.cogs[2].x - cx
    let dy = world.cogs[2].y - cy
    let startDist = offset[0] * offset[0] + offset[1] * offset[1]
    check(dx * dx + dy * dy >= startDist,
      "dodge moved outward from offset " & $offset &
      " (ended " & $world.cogs[2].x & "," & $world.cogs[2].y & ")")
    if dx * dx + dy * dy > PourRadius * PourRadius:
      cleared.inc
    total.inc
  check(cleared * 100 >= total * 90,
    "dodge fully cleared the circle from " & $cleared & "/" & $total &
    " starting points (want at least 90 %)")
  done("the dodge reaction clears the shape within the fuse")

proc testPourLeavesAPool() =
  var world = quietWorld()
  world.parkEveryoneAwayFrom(PitCx, PitCy)
  world.telegraphs = @[Telegraph(id: 1, kind: tkPour, cx: PitCx + 200,
    cy: PitCy, radius: PourRadius, fuse: 0, drawnOn: 2)]
  world.resolveTelegraphs()
  checkEq(world.pools.len, 1, "a slag pour always leaves a pool")
  checkEq(world.pools[0].radius, PourRadius, "of the same radius")
  done("a slag pour leaves a pool")

when isMainModule:
  testCrucibleUnsoaked()
  testSpillCap()
  testCrucibleSplit()
  testMembershipIsAtResolution()
  testDeadCogDoesNotCount()
  testBodyCentreMembership()
  testDodgeLeavesTheShape()
  testPourLeavesAPool()
  echo "test_telegraphs: telegraph shapes, fuses and the crucible check out"
