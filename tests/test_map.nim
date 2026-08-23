## The authored floor: data/foundry.mapspec.json and the masks baked from it.

import std/[json, sets]
import support/helpers

proc testSpecLoads() =
  let spec = parseJson(repoFile("data/foundry.mapspec.json"))
  checkEq(spec["name"].getStr(), "foundry", "one authored map")
  checkEq(spec["width"].getInt(), MapWidth, "map width")
  checkEq(spec["height"].getInt(), MapHeight, "map height")
  checkEq(spec["pit"]["cx"].getInt(), PitCx, "pit centre x")
  checkEq(spec["pit"]["cy"].getInt(), PitCy, "pit centre y")
  checkEq(spec["pit"]["r"].getInt(), PitRadius, "pit radius")
  checkEq(spec["pillars"].len, 4, "four pillars")
  checkEq(spec["cog_spawns"].len, Seats, "five cog spawns")
  checkEq(spec["add_alcoves"].len, 4, "four add alcoves")
  let arena = sharedArena
  checkEq(arena.name, "foundry", "and it is what the sim loads")
  done("data/foundry.mapspec.json loads")

proc insideAPillar(arena: Arena, x, y: int): bool =
  for pillar in arena.pillars:
    if x >= pillar[0] and x < pillar[0] + pillar[2] and
        y >= pillar[1] and y < pillar[1] + pillar[3]:
      return true
  false

proc testFourFoldSymmetry() =
  ## The PIT is four-fold symmetric about its centre. The pillars are 40 px
  ## wide about odd centres, so their pixel spans mirror one pixel across -
  ## their CENTRES are what the fairness of the floor rests on, and those are
  ## asserted exactly below.
  let arena = sharedArena
  var checked = 0
  for y in countup(0, arena.height - 1, 3):
    for x in countup(0, arena.width - 1, 3):
      let mirrorX = 2 * PitCx - x
      let mirrorY = 2 * PitCy - y
      if mirrorX < 0 or mirrorX >= arena.width:
        continue
      if mirrorY < 0 or mirrorY >= arena.height:
        continue
      if arena.insideAPillar(x, y) or arena.insideAPillar(mirrorX, y) or
          arena.insideAPillar(x, mirrorY):
        continue
      checkEq(arena.isWall(x, y), arena.isWall(mirrorX, y),
        "the pit mirrors about x at " & $x & "," & $y)
      checkEq(arena.isWall(x, y), arena.isWall(x, mirrorY),
        "the pit mirrors about y at " & $x & "," & $y)
      checked.inc
  check(checked > 50000, "the symmetry sweep covered the board")
  ## Pillar centres form an exact four-fold orbit at radius 150.
  var centres: seq[(int, int)]
  for pillar in arena.pillars:
    centres.add((pillar[0] + pillar[2] div 2, pillar[1] + pillar[3] div 2))
  checkEq(centres, @[(511, 223), (723, 223), (511, 435), (723, 435)],
    "the four pillar centres are the design note's quartet")
  for centre in centres:
    let dx = centre[0] - PitCx
    let dy = centre[1] - PitCy
    checkEq(dx * dx + dy * dy, 2 * 106 * 106,
      "each pillar centre sits 106 px out on both axes, radius ~150")
    check((2 * PitCx - centre[0], centre[1]) in centres,
      "mirrored about x")
    check((centre[0], 2 * PitCy - centre[1]) in centres,
      "mirrored about y")
  done("the pit is four-fold symmetric about (617, 329)")

proc testEveryAnchorIsOnFreeFloor() =
  let arena = sharedArena
  var seen: HashSet[(int, int)]
  for index, spawn in arena.cogSpawns:
    check(arena.canOccupyCog(spawn[0], spawn[1]),
      "cog spawn " & $index & " is on free floor")
    check(withinPx(spawn[0], spawn[1], PitCx, PitCy, PitRadius),
      "and inside the pit")
    check((spawn[0], spawn[1]) notin seen, "and does not overlap another")
    seen.incl((spawn[0], spawn[1]))
    for other in arena.cogSpawns:
      if other != spawn:
        check(distSq(spawn[0], spawn[1], other[0], other[1]) >
          (PlayerHalf * 2) * (PlayerHalf * 2),
          "spawns are further apart than two bodies")
  for index, alcove in arena.addAlcoves:
    check(arena.canOccupyAdd(alcove[0], alcove[1]),
      "add alcove " & $index & " is on free floor")
    check(withinPx(alcove[0], alcove[1], PitCx, PitCy, PitRadius),
      "and inside the pit")
  check(arena.canOccupyAdd(arena.bossStand[0], arena.bossStand[1]) == false,
    "the boss stand is solid to bodies")
  check(not arena.isWall(arena.bossStand[0], arena.bossStand[1]),
    "but transparent to sight, so cogs can shoot it")
  ## Every point on the two rings is legal floor.
  for brad in 0 ..< 256:
    for ring in [arena.rangedRing, arena.edgeRing]:
      let x = PitCx + BradX[brad] * ring div 1024
      let y = PitCy + BradY[brad] * ring div 1024
      check(withinPx(x, y, PitCx, PitCy, PitRadius),
        "ring point at brad " & $brad & " is inside the pit")
  done("every spawn, alcove and ring point is legal")

proc testLineOfSightFromEverySpawn() =
  let arena = sharedArena
  for index, spawn in arena.cogSpawns:
    check(arena.lineOfSightClear(spawn[0], spawn[1], arena.bossStand[0],
      arena.bossStand[1]),
      "cog spawn " & $index & " can see the boss stand")
  done("every cog spawn has line of sight to the boss")

proc testPillarsAreTheOnlyInteriorObstacles() =
  let arena = sharedArena
  var interiorWalls = 0
  var pillarPixels = 0
  for y in 0 ..< arena.height:
    for x in 0 ..< arena.width:
      if not withinPx(x, y, PitCx, PitCy, PitRadius):
        continue
      if not arena.isWall(x, y):
        continue
      interiorWalls.inc
      check(arena.insideAPillar(x, y),
        "the only interior wall pixels are pillars (found " & $x & "," & $y & ")")
      pillarPixels.inc
  checkEq(interiorWalls, 4 * 40 * 40, "four 40x40 pillars, no more")
  done("the four pillars are the only interior obstacles")

proc testPillarsBlockSight() =
  let arena = sharedArena
  for pillar in arena.pillars:
    let cx = pillar[0] + pillar[2] div 2
    let cy = pillar[1] + pillar[3] div 2
    check(not arena.lineOfSightClear(cx - 60, cy, cx + 60, cy),
      "a pillar blocks sight horizontally across its own footprint")
    check(not arena.lineOfSightClear(cx, cy - 60, cx, cy + 60),
      "and vertically")
    check(arena.lineOfSightClear(cx - 60, cy - 60, cx - 30, cy - 60),
      "while floor beside it stays clear")
  done("each pillar blocks sight across its own footprint")

when isMainModule:
  testSpecLoads()
  testFourFoldSymmetry()
  testEveryAnchorIsOnFreeFloor()
  testLineOfSightFromEverySpawn()
  testPillarsAreTheOnlyInteriorObstacles()
  testPillarsBlockSight()
  echo "test_map: the authored floor checks out"
