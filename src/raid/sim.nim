## The step loop. Everything here is integer arithmetic: no `sin`, `cos`,
## `tan`, `atan2`, `pow`, `exp`, `ln`, `fmod`, `hypot` or square root, and no
## floating-point value of any kind. Same seed plus same control bytes gives
## the same digest at every keyframe, in the native build and in the
## emscripten build, and CI greps this directory to keep it that way.
##
## The 19 numbered steps below are the design note's resolution order,
## unchanged and in order.

import std/[json]
import types, config, arena, state, events, labels, combat, pools, telegraphs,
  abilities, boss, orders, control

export types, config, arena, state, events, labels, combat, pools,
  telegraphs, abilities, boss, orders, control

const
  CogSolidSpan = PlayerHalf * 2 - 1
  AddSolidSpan = AddHalf * 2 - 1

proc slideScanRadius(carry, velocity: int): int =
  let pending = abs(carry) div MotionScale
  let speed = (abs(velocity) + MotionScale - 1) div MotionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

# ---- cog motion (paintbot's integer core) ------------------------------

proc cogOverlapAt(sim: Sim, moving, x, y: int): bool =
  for i in 0 ..< sim.cogs.len:
    if i == moving or not sim.cogs[i].alive:
      continue
    if max(abs(x - sim.cogs[i].x), abs(y - sim.cogs[i].y)) <= CogSolidSpan:
      return true
  false

proc blockingCogAt(sim: Sim, moving, fromX, fromY, toX, toY: int): int =
  ## A step is blocked when it lands overlapping another body WITHOUT
  ## increasing the separation, so bodies that start overlapped can escape.
  for i in 0 ..< sim.cogs.len:
    if i == moving or not sim.cogs[i].alive:
      continue
    let toDist = max(abs(toX - sim.cogs[i].x), abs(toY - sim.cogs[i].y))
    if toDist > CogSolidSpan:
      continue
    let fromDist = max(abs(fromX - sim.cogs[i].x), abs(fromY - sim.cogs[i].y))
    if toDist <= fromDist:
      return i
  -1

proc cogSlideOk(sim: Sim, moving, x, y, step, offset: int,
    horizontal: bool): bool =
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    let px = if horizontal: x else: x + slideStep * i
    let py = if horizontal: y + slideStep * i else: y
    if not sim.arena.canOccupyCog(px, py) or sim.cogOverlapAt(moving, px, py):
      return false
  let fx = if horizontal: x + step else: x + offset
  let fy = if horizontal: y + offset else: y + step
  sim.arena.canOccupyCog(fx, fy) and not sim.cogOverlapAt(moving, fx, fy)

proc cogTrySlide(sim: var Sim, moving, step, radius, preferred: int,
    horizontal: bool): bool =
  let pref = signOf(preferred)
  for distance in 1 .. radius:
    var candidates: array[2, int]
    if pref != 0:
      candidates = [pref * distance, -pref * distance]
    else:
      candidates = [-distance, distance]
    for offset in candidates:
      if sim.cogSlideOk(moving, sim.cogs[moving].x, sim.cogs[moving].y, step,
          offset, horizontal):
        if horizontal:
          sim.cogs[moving].x += step
          sim.cogs[moving].y += offset
        else:
          sim.cogs[moving].x += offset
          sim.cogs[moving].y += step
        return true
  false

proc bounceCogs(sim: var Sim, a, b: int, horizontal: bool) =
  let v1 = if horizontal: sim.cogs[a].velX else: sim.cogs[a].velY
  let v2 = if horizontal: sim.cogs[b].velX else: sim.cogs[b].velY
  let total = v1 + v2
  let rebound = (v1 - v2) * PlayerBouncePct div 100
  if horizontal:
    sim.cogs[a].velX = (total - rebound) div 2
    sim.cogs[b].velX = (total + rebound) div 2
  else:
    sim.cogs[a].velY = (total - rebound) div 2
    sim.cogs[b].velY = (total + rebound) div 2

proc applyCogAxis(sim: var Sim, index, preferred: int, horizontal: bool) =
  let velocity =
    if horizontal: sim.cogs[index].velX else: sim.cogs[index].velY
  var carry =
    (if horizontal: sim.cogs[index].carryX else: sim.cogs[index].carryY) +
    velocity
  while abs(carry) >= MotionScale:
    let step = if carry < 0: -1 else: 1
    let nx = if horizontal: sim.cogs[index].x + step else: sim.cogs[index].x
    let ny = if horizontal: sim.cogs[index].y else: sim.cogs[index].y + step
    var blocker = -1
    let free = sim.arena.canOccupyCog(nx, ny)
    if free:
      blocker = sim.blockingCogAt(index, sim.cogs[index].x, sim.cogs[index].y,
        nx, ny)
    if free and blocker < 0:
      if horizontal:
        sim.cogs[index].x = nx
      else:
        sim.cogs[index].y = ny
      carry -= step * MotionScale
    else:
      let radius = slideScanRadius(carry, velocity)
      if sim.cogTrySlide(index, step, radius, preferred, horizontal):
        carry -= step * MotionScale
      else:
        if blocker >= 0:
          sim.bounceCogs(index, blocker, horizontal)
        carry = 0
        break
  if horizontal:
    sim.cogs[index].carryX = carry
  else:
    sim.cogs[index].carryY = carry

proc moveCog*(sim: var Sim, index: int, moveX, moveY: int) =
  ## The analog step: `Accel` and the speed clamp are scaled by |move|/100 on
  ## each axis, so a diagonal is not faster than a cardinal.
  if moveX != 0:
    let accelX = max(1, Accel * abs(moveX) div 100)
    let bound = MaxSpeed * abs(moveX) div 100
    sim.cogs[index].velX = clamp(
      sim.cogs[index].velX + signOf(moveX) * accelX, -bound, bound)
  else:
    sim.cogs[index].velX =
      sim.cogs[index].velX * FrictionNum div FrictionDen
    if abs(sim.cogs[index].velX) < StopThreshold:
      sim.cogs[index].velX = 0
  if moveY != 0:
    let accelY = max(1, Accel * abs(moveY) div 100)
    let bound = MaxSpeed * abs(moveY) div 100
    sim.cogs[index].velY = clamp(
      sim.cogs[index].velY + signOf(moveY) * accelY, -bound, bound)
  else:
    sim.cogs[index].velY =
      sim.cogs[index].velY * FrictionNum div FrictionDen
    if abs(sim.cogs[index].velY) < StopThreshold:
      sim.cogs[index].velY = 0
  let preferX = if moveX != 0: signOf(moveX) else: signOf(sim.cogs[index].velX)
  let preferY = if moveY != 0: signOf(moveY) else: signOf(sim.cogs[index].velY)
  sim.applyCogAxis(index, preferY, true)
  sim.applyCogAxis(index, preferX, false)

# ---- add motion --------------------------------------------------------

proc addBlockedAt(sim: Sim, moving, x, y: int): bool =
  if not sim.arena.canOccupyAdd(x, y):
    return true
  for i in 0 ..< sim.adds.len:
    if i == moving or not sim.adds[i].alive:
      continue
    if max(abs(x - sim.adds[i].x), abs(y - sim.adds[i].y)) <= AddSolidSpan:
      return true
  for cog in sim.cogs:
    if not cog.alive:
      continue
    if max(abs(x - cog.x), abs(y - cog.y)) <= AddHalf + PlayerHalf - 1:
      return true
  false

proc applyAddAxis(sim: var Sim, index: int, horizontal: bool) =
  let velocity = if horizontal: sim.adds[index].velX else: sim.adds[index].velY
  var carry =
    (if horizontal: sim.adds[index].carryX else: sim.adds[index].carryY) +
    velocity
  while abs(carry) >= MotionScale:
    let step = if carry < 0: -1 else: 1
    let nx = if horizontal: sim.adds[index].x + step else: sim.adds[index].x
    let ny = if horizontal: sim.adds[index].y else: sim.adds[index].y + step
    if not sim.addBlockedAt(index, nx, ny):
      if horizontal:
        sim.adds[index].x = nx
      else:
        sim.adds[index].y = ny
      carry -= step * MotionScale
    else:
      carry = 0
      break
  if horizontal:
    sim.adds[index].carryX = carry
  else:
    sim.adds[index].carryY = carry

proc moveAdds(sim: var Sim) =
  for i in 0 ..< sim.adds.len:
    if not sim.adds[i].alive:
      continue
    let target = sim.adds[i].target
    var moveX = 0
    var moveY = 0
    if target >= 0 and target < sim.cogs.len and sim.cogs[target].alive:
      let dx = sim.cogs[target].x - sim.adds[i].x
      let dy = sim.cogs[target].y - sim.adds[i].y
      if dx * dx + dy * dy > AddRange * AddRange:
        var (ux, uy) = scaleToLength(dx, dy, 100)
        if sim.adds[i].stuckRotate > 0:
          let index = (((bearingBrads(ux, uy) + 16) div 32) +
            sim.adds[i].stuckRotate) mod 8
          ux = DirTable[index][0]
          uy = DirTable[index][1]
        moveX = ux
        moveY = uy
        sim.adds[i].aim = bearingBrads(dx, dy)
    if moveX != 0:
      let bound = AddMaxSpeed * abs(moveX) div 100
      sim.adds[i].velX = clamp(
        sim.adds[i].velX + signOf(moveX) * max(1, Accel * abs(moveX) div 100),
        -bound, bound)
    else:
      sim.adds[i].velX = sim.adds[i].velX * FrictionNum div FrictionDen
      if abs(sim.adds[i].velX) < StopThreshold:
        sim.adds[i].velX = 0
    if moveY != 0:
      let bound = AddMaxSpeed * abs(moveY) div 100
      sim.adds[i].velY = clamp(
        sim.adds[i].velY + signOf(moveY) * max(1, Accel * abs(moveY) div 100),
        -bound, bound)
    else:
      sim.adds[i].velY = sim.adds[i].velY * FrictionNum div FrictionDen
      if abs(sim.adds[i].velY) < StopThreshold:
        sim.adds[i].velY = 0
    sim.applyAddAxis(i, true)
    sim.applyAddAxis(i, false)

# ---- unstick bookkeeping ----------------------------------------------

proc updateUnstick(sim: var Sim, ctl: openArray[ControlOut]) =
  if sim.tick mod UnstickWindow != 0 or sim.tick == 0:
    return
  for i in 0 ..< sim.cogs.len:
    let moved = abs(sim.cogs[i].x - sim.cogs[i].histX) +
      abs(sim.cogs[i].y - sim.cogs[i].histY)
    let wanted = ctl[i].moveX != 0 or ctl[i].moveY != 0
    if wanted and moved < UnstickMinPx:
      sim.cogs[i].stuckRotate = (sim.cogs[i].stuckRotate + 1) mod 8
      if sim.cogs[i].stuckRotate == 0:
        sim.cogs[i].stuckRotate = 1
    else:
      sim.cogs[i].stuckRotate = 0
    sim.cogs[i].histX = sim.cogs[i].x
    sim.cogs[i].histY = sim.cogs[i].y
  for i in 0 ..< sim.adds.len:
    let moved = abs(sim.adds[i].x - sim.adds[i].histX) +
      abs(sim.adds[i].y - sim.adds[i].histY)
    if sim.adds[i].alive and moved < UnstickMinPx:
      sim.adds[i].stuckRotate = (sim.adds[i].stuckRotate + 1) mod 8
      if sim.adds[i].stuckRotate == 0:
        sim.adds[i].stuckRotate = 1
    else:
      sim.adds[i].stuckRotate = 0
    sim.adds[i].histX = sim.adds[i].x
    sim.adds[i].histY = sim.adds[i].y

# ---- keyframes ---------------------------------------------------------

proc appendKeyframe(sim: var Sim) =
  var frame = Keyframe(t: sim.tick, digest: sim.raidStateDigest())
  for cog in sim.cogs:
    let stateCode =
      if not cog.alive: 2
      elif cog.casting != ckNone: 1
      else: 0
    frame.cogs.add([cog.x, cog.y, cog.aim, max(0, cog.hp), cog.shield,
      cog.mana, stateCode])
  frame.boss = [sim.boss.x, sim.boss.y, sim.boss.aim, max(0, sim.boss.hp),
    sim.boss.phase, (if sim.boss.feed: 1 else: 0), sim.boss.spillStacks]
  for a in sim.adds:
    if a.alive:
      frame.adds.add([a.id, a.x, a.y, a.hp])
  for pool in sim.pools:
    frame.pools.add([pool.id, pool.cx, pool.cy, pool.radius,
      sim.tick - pool.spawnTick])
  for tel in sim.telegraphs:
    let kindCode = ord(tel.kind)
    let shape = if tel.kind == tkCleave: tel.facing else: tel.radius
    frame.tel.add([tel.id, kindCode, tel.cx, tel.cy, shape, tel.fuse,
      tel.soakNeeded])
  for cog in sim.cogs:
    frame.meters.add([cog.damageToBoss, cog.damageToAdds, cog.healingDone,
      cog.damageTaken])
  sim.keyframes.add(frame)

# ---- orders ------------------------------------------------------------

proc turnBoundary*(sim: Sim): bool =
  sim.tick mod sim.config.turnTicks == 0

proc turnCount*(sim: Sim): int =
  (sim.config.maxTicks + sim.config.turnTicks - 1) div sim.config.turnTicks

proc installOrders*(sim: var Sim, incoming: openArray[Order],
    sources: openArray[OrderSource], latencies: openArray[int]) =
  ## Step 1: the orders collected for this turn become the standing orders,
  ## and last turn's `say` strings become this turn's public callouts.
  sim.turn = sim.tick div sim.config.turnTicks
  for slot in 0 ..< sim.cogs.len:
    sim.says[slot] = sim.pendingSays[slot]
  sim.record("turn_start", %*{
    "turn": sim.turn, "boss_hp_pct": sim.bossHpPct(),
    "alive": sim.aliveCount(),
    "enrage_in_s": max(0.0,
      (sim.config.enrageTicks - sim.tick).float / TargetFps.float)
  })
  for slot in 0 ..< sim.cogs.len:
    if not sim.cogs[slot].alive:
      sim.pendingSays[slot] = ""
      continue
    if slot < incoming.len:
      sim.orders[slot] = repairOrder(sim, slot, incoming[slot])
      sim.orderSources[slot] =
        if slot < sources.len: sources[slot] else: osScripted
      sim.haveOrder[slot] = true
    sim.pendingSays[slot] = sim.orders[slot].say
    if sim.orderSources[slot] == osLlm:
      sim.cogs[slot].llmTurns.inc
    elif sim.orderSources[slot] == osFallback:
      sim.cogs[slot].fallbackTurns.inc
    var record = orderToJson(sim.orders[slot])
    record["turn"] = %sim.turn
    record["seat"] = %slot
    record["alias"] = %aliasOf(slot)
    record["role"] = %($sim.cogs[slot].role)
    record["source"] = %($sim.orderSources[slot])
    record["latency_ms"] = %(if slot < latencies.len: latencies[slot] else: 0)
    sim.record("order", record)

# ---- the step ----------------------------------------------------------

proc finish*(sim: var Sim, reason, endRule: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.endRule = endRule
  if sim.phases.len > 0:
    sim.phases[^1].toTick = max(sim.phases[^1].fromTick, sim.tick - 1)

proc encounterStart*(sim: var Sim) =
  var aliases = newJArray()
  var roles = newJArray()
  for slot in 0 ..< sim.cogs.len:
    aliases.add(%aliasOf(slot))
    roles.add(%($sim.cogs[slot].role))
  sim.record("encounter_start", %*{
    "seed": sim.config.seed, "aliases": aliases, "roles": roles,
    "boss_max_hp": sim.boss.maxHp,
    "enrage_s": sim.config.enrageTicks.float / TargetFps.float,
    "hard_end_s": sim.config.maxTicks.float / TargetFps.float
  })

proc stepOnce*(sim: var Sim) =
  if sim.done:
    return
  let t = sim.tick

  ## 1. Clock.
  if t == sim.config.enrageTicks:
    sim.boss.enraged = true
    sim.record("enrage", %*{
      "elapsed_s": sim.elapsedSeconds(), "boss_hp_pct": sim.bossHpPct()
    })

  ## 2. Control compile, in seat order.
  var ctl = newSeq[ControlOut](sim.cogs.len)
  let firstTick = t mod sim.config.turnTicks == 0
  for slot in 0 ..< sim.cogs.len:
    ctl[slot] = compileControl(sim, slot, firstTick)

  ## 3. Quantise and record. These bytes are the whole input record.
  for slot in 0 ..< sim.cogs.len:
    let mx = clamp(ctl[slot].moveX, -100, 100)
    let my = clamp(ctl[slot].moveY, -100, 100)
    let turn = clamp(ctl[slot].aimTurn, -AimTurnRate, AimTurnRate)
    let action = ctl[slot].action and 0x1F
    ctl[slot].moveX = mx
    ctl[slot].moveY = my
    ctl[slot].aimTurn = turn
    ctl[slot].action = action
    sim.controls.add(cast[uint8](int8(mx)))
    sim.controls.add(cast[uint8](int8(my)))
    sim.controls.add(cast[uint8](int8(turn)))
    sim.controls.add(uint8(action))

  ## 4. Aim.
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].alive:
      sim.cogs[slot].aim =
        ((sim.cogs[slot].aim + ctl[slot].aimTurn) mod 256 + 256) mod 256
  sim.aimBoss()

  ## 5. Cog motion, then 6. add motion.
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].alive:
      sim.moveCog(slot, ctl[slot].moveX, ctl[slot].moveY)
  sim.moveAdds()
  sim.updateUnstick(ctl)

  ## 7. Timers.
  sim.tickTimers()
  sim.tickBossTimers()

  ## 8. Player abilities, in the fixed sub-order.
  sim.doInterrupts(ctl)
  sim.doTaunts(ctl)
  sim.doShields(ctl)
  sim.completeHeals()
  sim.doAttacks(ctl)
  sim.startHeals(ctl)

  ## 9/10. Threat is folded in by damageBoss/healCog; retarget on the beat.
  sim.retargetBoss()
  sim.retargetAdds()

  ## 11. Boss scheduling (an Overload that has finished casting lands first).
  sim.resolveOverload()
  sim.scheduleBoss()
  sim.updateAddWaves()

  ## 12. Telegraph resolution, then 13. pools.
  sim.resolveTelegraphs()
  sim.updatePools()

  ## 14. Boss and add attacks.
  sim.bossAndAddAttacks()

  ## 15. Deaths.
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].alive and sim.cogs[slot].hp <= 0:
      sim.cogs[slot].alive = false
      sim.cogs[slot].hp = 0
      sim.cogs[slot].deathTick = t
      sim.cogs[slot].casting = ckNone
      sim.cogs[slot].castTicks = 0
      sim.cogs[slot].velX = 0
      sim.cogs[slot].velY = 0
      sim.deaths.inc
      sim.record("death", %*{
        "alias": aliasOf(slot), "role": $sim.cogs[slot].role,
        "killer": sim.cogs[slot].killer, "elapsed_s": sim.elapsedSeconds(),
        "alive_left": sim.aliveCount()
      })
  for i in 0 ..< sim.adds.len:
    if sim.adds[i].alive and sim.adds[i].hp <= 0:
      sim.adds[i].alive = false
      sim.addsKilled.inc
      sim.record("add_death", %*{
        "id": addName(sim.adds[i].id), "killer": sim.adds[i].killer,
        "alive_after": sim.addsAlive()
      })
  sim.updateFeed()

  ## 16. Phase check.
  sim.checkPhase()

  ## 17. Meters accrue inside the damage funnel; 18. keyframe.
  if sim.keyframeEvery > 0 and t mod sim.keyframeEvery == 0:
    sim.appendKeyframe()

  ## 19. End check.
  let fault = sim.guardInvariants()
  sim.tick = t + 1
  if fault.len > 0:
    sim.faultDetail = fault
    sim.finish("fault", "sim_fault")
  elif sim.boss.hp <= 0:
    sim.finish("complete", "kill")
  elif sim.aliveCount() == 0:
    sim.finish("complete", "wipe")
  elif sim.tick >= sim.config.maxTicks:
    sim.finish("complete", "enrage_timeout")

proc scriptedPlaceholder*(sim: Sim, slot: int): Order =
  ## A legal standing order, used before the first real turn arrives.
  Order(
    intent: defaultIntentFor(sim.cogs[slot].role),
    station: defaultStationFor(sim.cogs[slot].role),
    target: "boss", onTelegraph: rxDodge,
    px: sim.cogs[slot].x, py: sim.cogs[slot].y, hasPoint: true
  )
