## Runs without Polyworld, a graphics context or optional dependencies.
import support/helpers
import raid/polyworld_presentation

proc checkRaster(shape: HazardShape) =
  var cells = newSeq[bool]((shape.radius * 2 + 1) * (shape.radius * 2 + 1))
  let width = shape.radius * 2 + 1
  for span in shape.spans:
    for x in span.first .. span.last:
      let i = (span.y - shape.cy + shape.radius) * width +
        x - shape.cx + shape.radius
      check(not cells[i], "spans do not overlap")
      cells[i] = true
  for y in shape.cy - shape.radius .. shape.cy + shape.radius:
    for x in shape.cx - shape.radius .. shape.cx + shape.radius:
      let i = (y - shape.cy + shape.radius) * width + x - shape.cx + shape.radius
      checkEq(cells[i], shape.contains(x, y), "raster preserves every cell")

var world = quietWorld()
for kind in [tkCleave, tkPour, tkCrucible]:
  let radius = if kind == tkCleave: CleaveReach
               elif kind == tkPour: PourRadius else: CrucibleRadius
  world.telegraphs = @[Telegraph(id: 7, kind: kind, cx: PitCx, cy: PitCy,
    radius: radius, reach: radius, facing: 37, halfBrads: CleaveHalfBrads,
    fuse: 1, soakNeeded: (if kind == tkCrucible: 1 else: 0))]
  let digest = world.raidStateDigest()
  let scene = projectScene(world)
  checkEq(world.raidStateDigest(), digest, "projection never mutates the sim")
  let shape = scene.hazards[0]
  checkEq(shape.radius, radius, "radius comes from the live sim")
  checkEq(shape.fuse, 1, "no rounded seconds or interpolated expiry")
  for y in PitCy - radius .. PitCy + radius:
    for x in PitCx - radius .. PitCx + radius:
      checkEq(shape.contains(x, y), world.telegraphContains(world.telegraphs[0], x, y),
        "presentation membership is canonical sim membership")
  checkRaster(shape)
  world.resolveTelegraphs()
  checkEq(projectScene(world).hazards.len, 1, "fuse one remains visible")
  world.telegraphs[0].fuse = 0
  world.resolveTelegraphs()
  checkEq(projectScene(world).hazards.len, 0, "resolved shape disappears")

world.boss.casting = bcOverload
world.boss.castTicks = 1
world.stand(2, world.boss.x + InterruptRange, world.boss.y)
check(projectScene(world).interrupts[0].inRange, "interrupt radius is inclusive")
world.stand(2, world.boss.x + InterruptRange + 1, world.boss.y)
check(not projectScene(world).interrupts[0].inRange, "outside interrupt radius")
world.boss.casting = bcNone
checkEq(projectScene(world).interrupts.len, 0, "completed cast disappears")
echo "test_polyworld_presentation: exact raster, expiry, interrupt boundaries hold"
