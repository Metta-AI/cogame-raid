## The foundry: one authored map, loaded from `data/<name>.mapspec.json` and
## baked into integer masks.
##
## Three masks come out of the bake:
##   `wall`    - pit exterior and pillars. Blocks movement AND line of sight.
##   `solid`   - `wall` plus the boss's body. Blocks movement only, so a cog
##               can still see (and shoot, and heal past) the thing it is
##               standing next to.
##   `freeCog` / `freeAdd` - "a body of this half-extent centred here is
##               entirely off `solid`", precomputed with a prefix sum so the
##               motion step's occupancy query is O(1).

import std/[json, os]
import types

type
  Arena* = ref object
    name*: string
    width*, height*: int
    cx*, cy*, radius*: int
    pillars*: seq[array[4, int]]     ## x, y, w, h (top-left)
    bossStand*: array[2, int]
    cogSpawns*: seq[array[2, int]]
    addAlcoves*: seq[array[2, int]]
    rangedRing*: int
    edgeRing*: int
    spec*: JsonNode                  ## the source document, inlined verbatim
    wall*: seq[bool]
    freeCog*: seq[bool]
    freeAdd*: seq[bool]

proc dataDir*(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data",
      ".." / "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc index(arena: Arena, x, y: int): int {.inline.} =
  y * arena.width + x

proc isWall*(arena: Arena, x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= arena.width or y >= arena.height:
    return true
  arena.wall[arena.index(x, y)]

proc canOccupyCog*(arena: Arena, x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= arena.width or y >= arena.height:
    return false
  arena.freeCog[arena.index(x, y)]

proc canOccupyAdd*(arena: Arena, x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= arena.width or y >= arena.height:
    return false
  arena.freeAdd[arena.index(x, y)]

proc lineOfSightClear*(arena: Arena, ax, ay, bx, by: int): bool =
  ## True when no wall pixel blocks the segment. Paintbot's integer walk
  ## (`src/ctf/sim.nim:590`), unchanged.
  let dx = bx - ax
  let dy = by - ay
  let steps = max(abs(dx), abs(dy))
  if steps == 0:
    return true
  for s in 1 .. steps:
    let rx = ax + dx * s div steps
    let ry = ay + dy * s div steps
    if arena.isWall(rx, ry):
      return false
  true

proc bakeFree(arena: Arena, solid: seq[bool], half: int): seq[bool] =
  ## `result[i]` is true when a (2*half+1) square centred on that pixel holds
  ## no solid pixel and lies wholly inside the map.
  let w = arena.width
  let h = arena.height
  let stride = w + 1
  var prefix = newSeq[int32](stride * (h + 1))
  for y in 0 ..< h:
    var rowAcc: int32 = 0
    let base = y * w
    let outBase = (y + 1) * stride
    let prevBase = y * stride
    for x in 0 ..< w:
      if solid[base + x]:
        rowAcc += 1
      prefix[outBase + x + 1] = prefix[prevBase + x + 1] + rowAcc
  result = newSeq[bool](w * h)
  for y in half ..< h - half:
    let rowBase = y * w
    let y0 = y - half
    let y1 = y + half
    let topBase = y0 * stride
    let botBase = (y1 + 1) * stride
    for x in half ..< w - half:
      let x0 = x - half
      let x1 = x + half
      let total = prefix[botBase + x1 + 1] - prefix[botBase + x0] -
        prefix[topBase + x1 + 1] + prefix[topBase + x0]
      if total == 0:
        result[rowBase + x] = true

proc bake(arena: Arena) =
  let w = arena.width
  let h = arena.height
  arena.wall = newSeq[bool](w * h)
  var solid = newSeq[bool](w * h)
  let rr = arena.radius * arena.radius
  for y in 0 ..< h:
    let base = y * w
    let dy = y - arena.cy
    let dy2 = dy * dy
    for x in 0 ..< w:
      let dx = x - arena.cx
      if dx * dx + dy2 > rr:
        arena.wall[base + x] = true
  for pillar in arena.pillars:
    for y in pillar[1] ..< pillar[1] + pillar[3]:
      if y < 0 or y >= h:
        continue
      let base = y * w
      for x in pillar[0] ..< pillar[0] + pillar[2]:
        if x < 0 or x >= w:
          continue
        arena.wall[base + x] = true
  for i in 0 ..< w * h:
    solid[i] = arena.wall[i]
  ## The boss is bolted to its stand: solid to bodies, transparent to sight.
  let bx = arena.bossStand[0]
  let by = arena.bossStand[1]
  for y in by - BossHalf .. by + BossHalf:
    if y < 0 or y >= h:
      continue
    let base = y * w
    for x in bx - BossHalf .. bx + BossHalf:
      if x < 0 or x >= w:
        continue
      solid[base + x] = true
  arena.freeCog = bakeFree(arena, solid, PlayerHalf)
  arena.freeAdd = bakeFree(arena, solid, AddHalf)

proc arenaFromSpec*(spec: JsonNode): Arena =
  result = Arena(spec: spec)
  result.name = spec{"name"}.getStr("foundry")
  result.width = spec{"width"}.getInt(MapWidth)
  result.height = spec{"height"}.getInt(MapHeight)
  let pit = spec{"pit"}
  if pit == nil:
    raise newException(RaidError, "mapspec has no pit")
  result.cx = pit{"cx"}.getInt(PitCx)
  result.cy = pit{"cy"}.getInt(PitCy)
  result.radius = pit{"r"}.getInt(PitRadius)
  for pillar in spec{"pillars"}:
    result.pillars.add([
      pillar{"x"}.getInt(), pillar{"y"}.getInt(),
      pillar{"w"}.getInt(), pillar{"h"}.getInt()
    ])
  let stand = spec{"boss_stand"}
  result.bossStand = [stand[0].getInt(), stand[1].getInt()]
  for point in spec{"cog_spawns"}:
    result.cogSpawns.add([point[0].getInt(), point[1].getInt()])
  for point in spec{"add_alcoves"}:
    result.addAlcoves.add([point[0].getInt(), point[1].getInt()])
  result.rangedRing = spec{"ranged_ring_px"}.getInt(RangedRingPx)
  result.edgeRing = spec{"edge_ring_px"}.getInt(EdgeRingPx)
  if result.cogSpawns.len < Seats:
    raise newException(RaidError, "mapspec needs " & $Seats & " cog spawns")
  if result.addAlcoves.len < 4:
    raise newException(RaidError, "mapspec needs four add alcoves")
  result.bake()

proc mapSpecPath*(name: string): string =
  dataDir() / (name & ".mapspec.json")

proc loadArena*(name: string): Arena =
  let path = mapSpecPath(name)
  if not fileExists(path):
    raise newException(RaidError, "map spec not found: " & path)
  arenaFromSpec(parseJson(readFile(path)))
