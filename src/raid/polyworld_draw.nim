## Optional Polyworld consumer. This module never enters the simulation step.
import chroma, opengl, vmath
import polyworld/shapes
import types, polyworld_presentation

const RaidWorldScale* = 0.01'f32
proc point(x, y: float32): Vec3 = vec3(x * RaidWorldScale, 0, y * RaidWorldScale)

proc paint*(renderer: var ShapeRenderer, scene: RaidScene) =
  renderer.clear()
  renderer.addCircle(point(PitCx.float32, PitCy.float32),
    PitRadius.float32 * RaidWorldScale, rgbx(30, 38, 46, 254), sides = 256)
  for shape in scene.hazards:
    let color = if shape.soakNeeded > 0: rgbx(50, 220, 140, 190)
                else: rgbx(245, 110, 40, 190)
    for span in shape.spans:
      let a = span.first.float32 - 0.5'f32
      let b = span.last.float32 + 0.5'f32
      let y = span.y.float32
      renderer.addQuad(point(a, y - 0.5), point(b, y - 0.5),
        point(b, y + 0.5), point(a, y + 0.5), color)
  for marker in scene.interrupts:
    let disk = HazardShape(kind: skDisk, cx: marker.cx, cy: marker.cy,
      radius: marker.radius)
    for span in disk.spans:
      for x in [span.first, span.last]:
        renderer.addSquare(point(x.float32, span.y.float32), RaidWorldScale,
          rgbx(80, 190, 240, 90))
  for body in @[scene.boss] & scene.players:
    if body.alive:
      renderer.addSquare(point(body.x.float32, body.y.float32),
        body.halfSize.float32 * 2 * RaidWorldScale,
        if body.slot < 0: rgbx(230, 55, 65, 254)
        elif body.slot == 0: rgbx(70, 130, 245, 254)
        elif body.slot == 1: rgbx(50, 215, 110, 254)
        else: rgbx(245, 205, 75, 254))

proc raidProjection*(): Mat4 =
  for column in 0 .. 3:
    for row in 0 .. 3: result[column, row] = 0
  result[0, 0] = 2 / (MapWidth.float32 * RaidWorldScale)
  result[2, 1] = -2 / (MapHeight.float32 * RaidWorldScale)
  result[1, 2] = -0.01
  result[3, 0] = -1 + 1 / MapWidth.float32
  result[3, 1] = 1 - 1 / MapHeight.float32
  result[3, 3] = 1

proc drawScene*(renderer: var ShapeRenderer, scene: RaidScene, width, height: int) =
  glViewport(0, 0, width.GLsizei, height.GLsizei)
  glClearColor(0.03, 0.04, 0.05, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderer.paint(scene)
  renderer.draw(raidProjection())
  if glGetError() != GL_NO_ERROR:
    raise newException(RaidError, "Polyworld GL draw failed")
