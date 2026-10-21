## Experimental spectator projection. No policy names, notes, seed or prompts.
## Integer coordinates remain authoritative; only the drawing consumer scales.
import types, state

type
  ShapeKind* = enum
    skDisk, skCone
  HazardShape* = object
    id*, cx*, cy*, radius*, facing*, halfBrads*, fuse*, soakNeeded*: int
    kind*: ShapeKind
  BodyMarker* = object
    slot*, x*, y*, halfSize*, hp*: int
    alive*: bool
  InterruptMarker* = object
    slot*, cx*, cy*, radius*, remainingTicks*: int
    ready*, inRange*: bool
  RaidScene* = object
    tick*, phase*: int
    boss*: BodyMarker
    players*: seq[BodyMarker]
    hazards*: seq[HazardShape]
    interrupts*: seq[InterruptMarker]
  PixelSpan* = tuple[y, first, last: int]

proc contains*(shape: HazardShape, x, y: int): bool =
  case shape.kind
  of skDisk: withinPx(x, y, shape.cx, shape.cy, shape.radius)
  of skCone:
    inCone(shape.cx, shape.cy, shape.facing, shape.halfBrads,
      shape.radius, x, y)

iterator spans*(shape: HazardShape): PixelSpan =
  ## Exact occupied integer body-centre cells, not a polygonal circle guess.
  ## A consumer draws each inclusive span as a half-pixel-bounded rectangle.
  for y in shape.cy - shape.radius .. shape.cy + shape.radius:
    var first = low(int)
    for x in shape.cx - shape.radius .. shape.cx + shape.radius + 1:
      let inside = x <= shape.cx + shape.radius and shape.contains(x, y)
      if inside and first == low(int): first = x
      if not inside and first != low(int):
        yield (y, first, x - 1)
        first = low(int)

proc projectScene*(world: Sim): RaidScene =
  ## Called on a tick snapshot, with no interpolation or simulation writes.
  result.tick = world.tick
  result.phase = world.boss.phase
  result.boss = BodyMarker(slot: -1, x: world.boss.x, y: world.boss.y,
    halfSize: BossHalf, hp: world.boss.hp, alive: world.boss.hp > 0)
  for slot, cog in world.cogs:
    result.players.add(BodyMarker(slot: slot, x: cog.x, y: cog.y,
      halfSize: PlayerHalf, hp: cog.hp, alive: cog.alive))
    if world.boss.casting == bcOverload and cog.role == roleDps and cog.alive:
      result.interrupts.add(InterruptMarker(slot: slot, cx: cog.x, cy: cog.y,
        radius: InterruptRange, remainingTicks: world.boss.castTicks,
        ready: cog.interruptCd == 0,
        inRange: withinPx(cog.x, cog.y, world.boss.x, world.boss.y,
          InterruptRange)))
  for tel in world.telegraphs:
    let cone = tel.kind == tkCleave
    result.hazards.add(HazardShape(id: tel.id,
      kind: (if cone: skCone else: skDisk),
      cx: (if cone: world.boss.x else: tel.cx),
      cy: (if cone: world.boss.y else: tel.cy),
      radius: (if cone: tel.reach else: tel.radius), facing: tel.facing,
      halfBrads: tel.halfBrads, fuse: tel.fuse, soakNeeded: tel.soakNeeded))
