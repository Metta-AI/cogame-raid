## The control layer: the deterministic 24 Hz reflexes under the 0.2 Hz order.
##
## LLM orders and scripted orders are compiled by exactly this code, so the
## two policy kinds are strictly comparable and the recorded control bytes are
## the whole truth. It is a pure function of (world, seat) — nothing here
## reads a clock, a socket or an RNG.

import types, state, arena, labels, abilities, telegraphs

const
  DodgeSideStepPx = 150
  FreeProbeSpacing = 16

proc freeScoreAround(sim: Sim, x, y: int): int =
  ## How much open floor there is around a candidate, as an integer count of
  ## a 5x5 probe grid. Used to pick which way to leave a cleave cone.
  for gy in -2 .. 2:
    for gx in -2 .. 2:
      if sim.arena.canOccupyCog(x + gx * FreeProbeSpacing,
          y + gy * FreeProbeSpacing):
        result.inc

proc outwardFromCircle(sim: Sim, tel: Telegraph, x, y: int): (int, int) =
  ## The nearest point `DodgeMarginPx` outside a circle, along the outward
  ## direction. A cog standing exactly on the centre leaves toward the pit rim.
  var dx = x - tel.cx
  var dy = y - tel.cy
  if dx == 0 and dy == 0:
    dx = x - sim.boss.x
    dy = y - sim.boss.y
    if dx == 0 and dy == 0:
      dx = 1
  let want = tel.radius + PlayerHalf + DodgeMarginPx
  let (ux, uy) = scaleToLength(dx, dy, want)
  clampIntoPit(tel.cx + ux, tel.cy + uy)

proc sideStepFromCone(sim: Sim, tel: Telegraph, x, y: int): (int, int) =
  ## Perpendicular to the cone's bisector, on the side with more free floor.
  var best = (x, y)
  var bestScore = -1
  for side in [64, -64]:
    let brad = ((tel.facing + side) mod 256 + 256) mod 256
    let cx = x + BradX[brad] * DodgeSideStepPx div 1024
    let cy = y + BradY[brad] * DodgeSideStepPx div 1024
    let point = clampIntoPit(cx, cy)
    let score = freeScoreAround(sim, point[0], point[1])
    if score > bestScore:
      bestScore = score
      best = point
  best

proc centroidOfOthers(sim: Sim, slot: int): (int, int) =
  var sx = 0
  var sy = 0
  var count = 0
  for i, cog in sim.cogs:
    if i == slot or not cog.alive:
      continue
    sx += cog.x
    sy += cog.y
    count.inc
  if count == 0:
    return (sim.cogs[slot].x, sim.cogs[slot].y)
  (sx div count, sy div count)

proc nearestOtherCog(sim: Sim, slot: int): int =
  var best = -1
  var bestDist = high(int)
  for i, cog in sim.cogs:
    if i == slot or not cog.alive:
      continue
    let d = distSq(sim.cogs[slot].x, sim.cogs[slot].y, cog.x, cog.y)
    if d < bestDist:
      bestDist = d
      best = i
  best

proc addIndexOfTarget(sim: Sim, target: string): int =
  if target.len < 2 or target[0] != 'A':
    return -1
  var id = 0
  for i in 1 ..< target.len:
    if target[i] < '0' or target[i] > '9':
      return -1
    id = id * 10 + (ord(target[i]) - ord('0'))
  sim.addIndexById(id)

proc resolveAttack*(sim: Sim, slot: int, order: Order): (AttackKind, int) =
  ## The attack target is re-derived from the recorded state, never stored in
  ## the control bytes.
  let bossUp = sim.boss.hp > 0
  case order.intent
  of inPickUpAdds, inKillAdds:
    var index = addIndexOfTarget(sim, order.target)
    if index < 0 or not sim.adds[index].alive:
      index = sim.nearestLivingAdd(sim.cogs[slot].x, sim.cogs[slot].y)
    if index >= 0:
      return (atAdd, index)
    if bossUp:
      return (atBoss, -1)
    return (atNone, -1)
  of inWait:
    return (atNone, -1)
  of inAssistTarget:
    let ally = slotOfAlias(order.target)
    if ally >= 0 and sim.cogs[ally].alive:
      let mirrored = sim.cogs[ally].attacking
      if mirrored.len > 0 and mirrored != "boss":
        let index = addIndexOfTarget(sim, mirrored)
        if index >= 0 and sim.adds[index].alive:
          return (atAdd, index)
    if bossUp:
      return (atBoss, -1)
    return (atNone, -1)
  else:
    if order.target.len > 0 and order.target[0] == 'A' and
        slotOfAlias(order.target) < 0:
      let index = addIndexOfTarget(sim, order.target)
      if index >= 0 and sim.adds[index].alive:
        return (atAdd, index)
    if bossUp:
      return (atBoss, -1)
    return (atNone, -1)

proc healReachable(sim: Sim, slot, target: int): bool =
  target >= 0 and target < sim.cogs.len and sim.cogs[target].alive and
    sim.canReach(slot, sim.cogs[target].x, sim.cogs[target].y, HealRange)

proc lowestReachableAlly(sim: Sim, slot: int): int =
  ## Lowest hp FRACTION among living allies the healer can actually reach. A
  ## heal on an ally 380 px away behind a pillar is not a heal at all, and a
  ## healer standing still because its nominal target is unreachable is a
  ## wipe; so the choice is restricted to what a cast could land on, and only
  ## falls back to the raid-wide lowest when nothing is in reach.
  var best = -1
  var bestNum = 0
  var bestDen = 1
  for i, cog in sim.cogs:
    if not cog.alive or not healReachable(sim, slot, i):
      continue
    if best < 0 or cog.hp * bestDen < bestNum * cog.maxHp:
      best = i
      bestNum = cog.hp
      bestDen = cog.maxHp
  if best < 0: sim.lowestHpAlly() else: best

const HealWasteFloor* = 60
  ## Overheal is recorded and wasted and the 1200-point pool is the whole
  ## encounter's healing budget, so a cast that would throw away more than a
  ## third of itself is never begun.

proc worthHealing(sim: Sim, target: int): bool =
  ## Overheal is recorded and wasted, and the 1200-point pool is the whole
  ## encounter's healing budget: never BEGIN a cast that would throw away
  ## more than two thirds of itself.
  target >= 0 and target < sim.cogs.len and
    sim.cogs[target].maxHp - sim.cogs[target].hp >= HealWasteFloor

proc healTargetFor(sim: Sim, slot: int, order: Order): int =
  var target = -1
  case order.intent
  of inHealLowest:
    target = lowestReachableAlly(sim, slot)
  of inHealTarget:
    let named = slotOfAlias(order.target)
    target =
      if healReachable(sim, slot, named): named
      else: lowestReachableAlly(sim, slot)
  of inConserve:
    let ally = lowestReachableAlly(sim, slot)
    if ally >= 0 and sim.cogs[ally].hp * 100 < sim.cogs[ally].maxHp * 40:
      target = ally
  else:
    discard
  if not worthHealing(sim, target):
    return -1
  target

proc shieldTargetFor(sim: Sim, slot: int, order: Order): int =
  if order.intent == inShieldTarget:
    let named = slotOfAlias(order.target)
    if named >= 0 and sim.cogs[named].alive:
      return named
    return sim.lowestHpAlly()
  ## Automatic emergency shield: an ally under 40 % standing in a live
  ## telegraph, with the shield off cooldown.
  if sim.telegraphs.len == 0:
    return -1
  let tel = sim.telegraphs[0]
  for i, cog in sim.cogs:
    if not cog.alive:
      continue
    if cog.hp * 100 >= cog.maxHp * 40:
      continue
    if sim.telegraphContains(tel, cog.x, cog.y):
      return i
  -1

proc steeringPoint(sim: Sim, slot: int, order: Order): (int, int) =
  let me = sim.cogs[slot]
  ## 1. Reaction override.
  if sim.telegraphs.len > 0:
    let tel = sim.telegraphs[0]
    let inside = sim.telegraphContains(tel, me.x, me.y)
    case order.onTelegraph
    of rxDodge:
      if inside:
        if tel.kind == tkCleave:
          return sideStepFromCone(sim, tel, me.x, me.y)
        return outwardFromCircle(sim, tel, me.x, me.y)
    of rxSoak:
      ## Steer to the middle of the circle and STAY there: leaving it before
      ## the fuse burns is the same as never having soaked.
      if tel.kind != tkCleave:
        return clampIntoPit(tel.cx, tel.cy)
    of rxSpread:
      if inside:
        let centroid = centroidOfOthers(sim, slot)
        let (ux, uy) = scaleToLength(me.x - centroid[0], me.y - centroid[1],
          SpreadStepPx)
        if ux != 0 or uy != 0:
          return clampIntoPit(me.x + ux, me.y + uy)
    of rxHold:
      discard
  ## 2. Intent overrides that own the steering outright.
  if order.intent == inWait:
    return (me.x, me.y)
  if order.intent == inKite:
    let (ux, uy) = scaleToLength(me.x - sim.boss.x, me.y - sim.boss.y, KitePx)
    if ux == 0 and uy == 0:
      return (me.x, me.y)
    return clampIntoPit(me.x + ux, me.y + uy)
  var station = order.station
  if order.intent == inSoak:
    station = stSoak
  ## 3. Station.
  case station
  of stMelee:
    let (kind, index) = resolveAttack(sim, slot, order)
    var tx = sim.boss.x
    var ty = sim.boss.y
    if kind == atAdd and index >= 0:
      tx = sim.adds[index].x
      ty = sim.adds[index].y
    let (ux, uy) = scaleToLength(me.x - tx, me.y - ty, StationMelee)
    if ux == 0 and uy == 0:
      return clampIntoPit(tx + StationMelee, ty)
    return clampIntoPit(tx + ux, ty + uy)
  of stRanged:
    let (ux, uy) = scaleToLength(me.x - sim.boss.x, me.y - sim.boss.y,
      sim.arena.rangedRing)
    if ux == 0 and uy == 0:
      return clampIntoPit(sim.boss.x + sim.arena.rangedRing, sim.boss.y)
    return clampIntoPit(sim.boss.x + ux, sim.boss.y + uy)
  of stSpread:
    let nearest = nearestOtherCog(sim, slot)
    if nearest < 0 or
        distSq(me.x, me.y, sim.cogs[nearest].x, sim.cogs[nearest].y) >=
          SpreadPx * SpreadPx:
      return (me.x, me.y)
    let (ux, uy) = scaleToLength(me.x - sim.cogs[nearest].x,
      me.y - sim.cogs[nearest].y, SpreadPx)
    if ux == 0 and uy == 0:
      return (me.x, me.y)
    return clampIntoPit(me.x + ux, me.y + uy)
  of stEdge:
    let (ux, uy) = scaleToLength(me.x - PitCx, me.y - PitCy,
      sim.arena.edgeRing)
    if ux == 0 and uy == 0:
      return clampIntoPit(PitCx + sim.arena.edgeRing, PitCy)
    return clampIntoPit(PitCx + ux, PitCy + uy)
  of stPoint:
    return clampIntoPit(order.px, order.py)
  of stSoak:
    let index = sim.livePourTelegraph()
    if index >= 0:
      return clampIntoPit(sim.telegraphs[index].cx, sim.telegraphs[index].cy)
    let (ux, uy) = scaleToLength(me.x - sim.boss.x, me.y - sim.boss.y,
      sim.arena.rangedRing)
    if ux == 0 and uy == 0:
      return clampIntoPit(sim.boss.x + sim.arena.rangedRing, sim.boss.y)
    return clampIntoPit(sim.boss.x + ux, sim.boss.y + uy)

proc compileControl*(sim: Sim, slot: int, turnFirstTick: bool): ControlOut =
  ## The whole per-tick control byte pair for one living cog.
  result.attackKind = atNone
  result.attackAdd = -1
  result.healTarget = -1
  result.shieldTarget = -1
  if slot < 0 or slot >= sim.cogs.len or not sim.cogs[slot].alive:
    return
  let me = sim.cogs[slot]
  let order = sim.orders[slot]

  ## Movement.
  let goal = steeringPoint(sim, slot, order)
  let dx = goal[0] - me.x
  let dy = goal[1] - me.y
  if dx * dx + dy * dy > ArriveEpsilonPx * ArriveEpsilonPx:
    var (mx, my) = scaleToLength(dx, dy, 100)
    if me.stuckRotate > 0:
      ## No pathfinder: a cog that has not moved rotates its heading by 45
      ## degrees a second until it does. A station behind a pillar is a bad
      ## order, and reading the pit is part of the skill.
      let base = bearingBrads(mx, my)
      let index = (((base + 16) div 32) + me.stuckRotate) mod 8
      mx = DirTable[index][0]
      my = DirTable[index][1]
    result.moveX = clamp(mx, -100, 100)
    result.moveY = clamp(my, -100, 100)

  ## Attack target and aim.
  let (kind, index) = resolveAttack(sim, slot, order)
  result.attackKind = kind
  result.attackAdd = index
  var tx = me.x
  var ty = me.y
  var haveTarget = false
  if kind == atBoss:
    tx = sim.boss.x
    ty = sim.boss.y
    haveTarget = true
  elif kind == atAdd and index >= 0 and index < sim.adds.len:
    tx = sim.adds[index].x
    ty = sim.adds[index].y
    haveTarget = true
  if haveTarget and (tx != me.x or ty != me.y):
    let wanted = bearingBrads(tx - me.x, ty - me.y)
    result.aimTurn = clamp(bradDelta(me.aim, wanted), -AimTurnRate,
      AimTurnRate)

  ## Action bits.
  var action = 0
  if haveTarget and me.attackCd == 0 and me.casting == ckNone:
    let reach = roleRange(me.role)
    var alive = true
    if kind == atAdd:
      alive = index >= 0 and index < sim.adds.len and sim.adds[index].alive
    else:
      alive = sim.boss.hp > 0
    if alive and sim.canReach(slot, tx, ty, reach):
      action = action or ActAttack

  if me.role == roleTank:
    let wantTaunt =
      (order.intent == inTaunt and turnFirstTick) or
      (order.intent == inTankBoss and sim.boss.target != slot)
    if wantTaunt and me.tauntCd == 0:
      action = action or ActTaunt
      result.tauntNow = true

  if me.role == roleHealer:
    ## A cast is cancelled by 8 px of movement, so never START one while the
    ## controller still intends to walk: a cancelled cast is a second of
    ## healing thrown away, and the tank's margin does not have one to spare.
    let planted = result.moveX == 0 and result.moveY == 0
    let heal = healTargetFor(sim, slot, order)
    if planted and heal >= 0 and me.mana >= HealCost and me.casting == ckNone:
      result.healTarget = heal
      action = action or ActHeal
    let shield = shieldTargetFor(sim, slot, order)
    if shield >= 0 and me.shieldCd == 0 and me.mana >= ShieldCost:
      result.shieldTarget = shield
      action = action or ActShield

  if me.role == roleDps and order.intent == inInterrupt:
    if sim.boss.casting != bcNone and me.interruptCd == 0 and
        sim.canReach(slot, sim.boss.x, sim.boss.y, InterruptRange):
      action = action or ActInterrupt

  result.action = action
