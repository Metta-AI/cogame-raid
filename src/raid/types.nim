## Raid core types and constants.
##
## Everything the deterministic step touches is an integer. The motion
## constants are paintbot's (`src/ctf/sim_types.nim`), with `MaxSpeed`
## re-pinned to 832 so a cog can clear a 90 px pour centred on its own feet
## inside the 60-tick fuse (design note, "Bodies, motion, and the control
## bytes").
##
## The brad tables at the bottom are literal integers on purpose: the sim
## step may not call a single floating-point maths routine, and CI greps this
## directory for one.

import std/[strutils]

const
  GameVersion* = "1"
    ## GV1 (raid v1): SMELTER-9, three phases, 240 s enrage. The rules gate a
    ## replay is compared against; bump it whenever a recorded control byte
    ## would re-derive a different encounter.

  MapWidth* = 1235
  MapHeight* = 659
  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  StopThreshold* = 8
  PlayerHalf* = 6
  PlayerBouncePct* = 40
  MovementSlideMaxScan* = 3
  AimBradsTurn* = 256
  AimTurnRate* = 8
  MaxSpeed* = 832

  Seats* = 5
  Aliases* = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
  BossName* = "SMELTER-9"

  PitCx* = 617
  PitCy* = 329
  PitRadius* = 300
  ClampRadius* = 288
  RangedRingPx* = 260
  EdgeRingPx* = 280

  BossHalf* = 28
  AddHalf* = 8

  ## Roles.
  TankMaxHp* = 300
  HealerMaxHp* = 160
  DpsMaxHp* = 180
  TankRange* = 40
  HealerRange* = 300
  DpsRange* = 420
  TankAttackCd* = 12
  HealerAttackCd* = 24
  DpsAttackCd* = 18
  TankAttackDamage* = 12
  HealerAttackDamage* = 8
  DpsAttackDamage* = 34
  TankThreatMul* = 3

  TauntRange* = 200
  TauntCooldownTicks* = 192
  TauntLockTicks* = 72
  HealRange* = 360
  HealCastTicks* = 24
  HealAmount* = 90
  HealCost* = 60
  HealMoveCancelPx* = 8
  ShieldRange* = 360
  ShieldAbsorb* = 120
  ShieldCost* = 150
  ShieldCooldownTicks* = 360
  ShieldExpireTicks* = 480
  ManaMax* = 1200
  ManaRegenPerTick* = 30      ## added on every tick where t mod 24 == 0
  InterruptRange* = 420
  InterruptCooldownTicks* = 480

  ## Boss.
  BossMeleeTicks* = 36
  BossMeleeTicksEnraged* = 24
  BossMeleeRange* = 60
  BossMeleeDamage* = 55
  BossTurnRate* = 6

  CleaveHalfBrads* = 32
  CleaveReach* = 180
  CleaveTelegraphTicks* = 48
  CleaveDamage* = 120
  CleaveCadence* = [192, 192, 168, 144]  ## indexed by phase (1..3)
  CleaveFirstTick* = 96

  PourRadius* = 90
  PourTelegraphTicks* = 60
  PourDamage* = 80
  PourCadence* = [240, 240, 216, 0]      ## indexed by phase (1..2)
  PourFirstTick* = 192
  PoolTicks* = 240
  PoolBiteTicks* = 24
  PoolDamage* = 12
  PoolCap* = 6

  CrucibleRadius* = 110
  CrucibleTelegraphTicks* = 72
  CrucibleCadence* = 168
  CrucibleDamage* = 240
  SpillMaxStacks* = 5

  OverloadCastTicks* = 96
  OverloadCadence* = 480
  OverloadDamage* = 70
  OverloadHeal* = 400

  AddHp* = 220
  AddMaxSpeed* = 640
  AddRange* = 30
  AddDamage* = 18
  AddAttackTicks* = 24
  AddWaveSize* = 2
  AddWaveTicks* = 360
  AddCap* = 8
  FeedThreshold* = 4
  AddRetargetRange* = 400

  ## Order caps, in RUNES.
  MaxIntentRunes* = 16
  MaxTargetRunes* = 12
  MaxStationRunes* = 8
  MaxNoteRunes* = 160
  MaxSayRunes* = 32
  MaxPolicyLabelRunes* = 48
  MaxDetailRunes* = 200
  MaxPromptRunes* = 4000

  ## Control layer.
  StationMelee* = 40
  SpreadPx* = 140
  SpreadStepPx* = 160
  KitePx* = 120
  DodgeMarginPx* = 20
  ArriveEpsilonPx* = 8
  UnstickWindow* = 24
  UnstickMinPx* = 6

type
  RaidError* = object of CatchableError

  ScriptKind* = enum
    ## Which scripted baseline drives a seat. `PLAYER_SCRIPTED` selects one;
    ## a seat that names neither a prompt nor a baseline plays `stalwart`.
    skNone = "none"
    skStalwart = "stalwart"
    skGreenhorn = "greenhorn"

  Role* = enum
    roleTank = "tank"
    roleHealer = "healer"
    roleDps = "dps"

  Intent* = enum
    ## One order per decision turn. `soak` and `wait` are legal for every
    ## role; the rest are role-gated (see `intentLegalFor`).
    inTankBoss = "tank_boss"
    inTaunt = "taunt"
    inPickUpAdds = "pick_up_adds"
    inKite = "kite"
    inHealLowest = "heal_lowest"
    inHealTarget = "heal_target"
    inShieldTarget = "shield_target"
    inConserve = "conserve"
    inBurnBoss = "burn_boss"
    inKillAdds = "kill_adds"
    inInterrupt = "interrupt"
    inAssistTarget = "assist_target"
    inSoak = "soak"
    inWait = "wait"

  Station* = enum
    stMelee = "melee"
    stRanged = "ranged"
    stSpread = "spread"
    stEdge = "edge"
    stPoint = "point"
    stSoak = "soak"

  Reaction* = enum
    rxDodge = "dodge"
    rxHold = "hold"
    rxSoak = "soak"
    rxSpread = "spread"

  Order* = object
    intent*: Intent
    target*: string          ## canonical: "", "boss", "A<n>", or an alias
    station*: Station
    px*, py*: int
    hasPoint*: bool
    onTelegraph*: Reaction
    note*: string
    say*: string

  OrderSource* = enum
    osScripted = "scripted"
    osLlm = "llm"
    osFallback = "fallback"

  FallbackCause* = enum
    fcNone = "none"
    fcTimeout = "timeout"
    fcParse = "parse_error"
    fcTransport = "transport_error"
    fcNoCreds = "no_credentials"
    fcBudget = "budget_guard"

  Decision* = object
    ## One seat's answer for one turn, plus how it was arrived at.
    order*: Order
    source*: OrderSource
    latencyMs*: int
    attempts*: int
    cause*: FallbackCause
    detail*: string

  CastKind* = enum
    ckNone = "none"
    ckHeal = "heal"

  BossCast* = enum
    bcNone = "none"
    bcOverload = "overload"

  TelegraphKind* = enum
    tkCleave = "cleave"
    tkPour = "pour"
    tkCrucible = "crucible"

  Cog* = object
    slot*: int
    role*: Role
    x*, y*: int              ## body centre, map pixels
    velX*, velY*: int
    carryX*, carryY*: int
    aim*: int                ## brads
    hp*, maxHp*: int
    shield*: int
    shieldTicks*: int
    mana*: int
    alive*: bool
    deathTick*: int
    killer*: string
    attackCd*: int
    tauntCd*: int
    shieldCd*: int
    interruptCd*: int
    casting*: CastKind
    castTicks*: int
    castTarget*: int
    castStartX*, castStartY*: int
    threat*: int
    attacking*: string
    ## Meters.
    damageToBoss*: int
    damageToAdds*: int
    healingDone*: int
    overhealing*: int
    damageTaken*: int
    avoidableHits*: int
    interruptsLanded*: int
    interruptsWasted*: int
    llmTurns*: int
    fallbackTurns*: int
    fbTimeout*, fbParse*, fbTransport*, fbNoCreds*, fbBudget*: int
    ## Unstick bookkeeping.
    histX*, histY*: int
    stuckRotate*: int

  Add* = object
    id*: int
    x*, y*: int
    velX*, velY*: int
    carryX*, carryY*: int
    aim*: int
    hp*: int
    alive*: bool
    target*: int
    attackCd*: int
    histX*, histY*: int
    stuckRotate*: int
    killer*: string
      ## Alias of the cog whose hit took the add to 0 hp, the way a cog
      ## carries the name of whatever killed it. Cosmetic: it feeds the
      ## `add_death` event and nothing in the step reads it, so it is not in
      ## `raidStateDigest`.

  Pool* = object
    id*: int
    cx*, cy*: int
    radius*: int
    spawnTick*: int
    alive*: bool

  Telegraph* = object
    id*: int
    kind*: TelegraphKind
    cx*, cy*: int
    radius*: int
    facing*: int
    halfBrads*: int
    reach*: int
    fuse*: int
    soakNeeded*: int
    drawnOn*: int            ## slot the pour was drawn on, -1 otherwise

  Boss* = object
    x*, y*: int
    aim*: int
    hp*, maxHp*: int
    phase*: int
    target*: int
    tauntLock*: int
    enraged*: bool
    spillStacks*: int
    feed*: bool
    meleeCd*: int
    cleaveCd*: int
    pourCd*: int
    overloadCd*: int
    addsCd*: int
    casting*: BossCast
    castTicks*: int
    castTotal*: int
    telegraphLive*: bool

  AttackKind* = enum
    atNone = "none"
    atBoss = "boss"
    atAdd = "add"

  ControlOut* = object
    ## One tick of one cog's control, as compiled by the control layer. The
    ## first four fields ARE the replay's per-tick record; the resolved
    ## targets below are re-derived identically from the recorded state, so
    ## they never have to be stored.
    moveX*, moveY*, aimTurn*, action*: int
    attackKind*: AttackKind
    attackAdd*: int          ## index into sim.adds when attackKind == atAdd
    healTarget*: int
    shieldTarget*: int
    tauntNow*: bool

  Keyframe* = object
    t*: int
    digest*: uint32
    cogs*: seq[array[7, int]]
    boss*: array[7, int]
    adds*: seq[array[4, int]]
    pools*: seq[array[5, int]]
    tel*: seq[array[7, int]]
    meters*: seq[array[4, int]]

  PhaseSpan* = object
    phase*: int
    name*: string
    fromTick*: int
    toTick*: int

  Pcg32* = object
    state*: uint64
    stream*: uint64

proc phaseName*(phase: int): string =
  case phase
  of 1: "Forge"
  of 2: "Slag"
  of 3: "Meltdown"
  else: "Forge"

proc roleMaxHp*(role: Role): int =
  case role
  of roleTank: TankMaxHp
  of roleHealer: HealerMaxHp
  of roleDps: DpsMaxHp

proc roleRange*(role: Role): int =
  case role
  of roleTank: TankRange
  of roleHealer: HealerRange
  of roleDps: DpsRange

proc roleAttackCd*(role: Role): int =
  case role
  of roleTank: TankAttackCd
  of roleHealer: HealerAttackCd
  of roleDps: DpsAttackCd

proc roleAttackDamage*(role: Role): int =
  case role
  of roleTank: TankAttackDamage
  of roleHealer: HealerAttackDamage
  of roleDps: DpsAttackDamage

proc intentLegalFor*(intent: Intent, role: Role): bool =
  if intent == inSoak or intent == inWait:
    return true
  case role
  of roleTank:
    intent in {inTankBoss, inTaunt, inPickUpAdds, inKite}
  of roleHealer:
    intent in {inHealLowest, inHealTarget, inShieldTarget, inConserve}
  of roleDps:
    intent in {inBurnBoss, inKillAdds, inInterrupt, inAssistTarget}

proc defaultIntentFor*(role: Role): Intent =
  case role
  of roleTank: inTankBoss
  of roleHealer: inHealLowest
  of roleDps: inBurnBoss

proc defaultStationFor*(role: Role): Station =
  if role == roleTank: stMelee else: stRanged

proc parseRole*(text: string): Role =
  case text.strip().toLowerAscii()
  of "tank": roleTank
  of "healer": roleHealer
  of "dps": roleDps
  else: raise newException(RaidError, "unknown role: " & text)

# ---- PCG32 -------------------------------------------------------------

proc initPcg32*(seed: int): Pcg32 =
  let raw = cast[uint64](seed)
  result.state = 0'u64
  result.stream = (raw shl 1'u64) or 1'u64
  result.state = result.state * 6364136223846793005'u64 + result.stream
  result.state = result.state + raw
  result.state = result.state * 6364136223846793005'u64 + result.stream

proc nextU32*(rng: var Pcg32): uint32 =
  let old = rng.state
  rng.state = old * 6364136223846793005'u64 + rng.stream
  let xorshifted = uint32(((old shr 18'u64) xor old) shr 27'u64)
  let rot = uint32(old shr 59'u64)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc below*(rng: var Pcg32, bound: int): int =
  ## Uniform in 0 ..< bound (bound > 0), integer only.
  if bound <= 1:
    return 0
  int(rng.nextU32() mod uint32(bound))

# ---- integer geometry --------------------------------------------------

proc signOf*(value: int): int {.inline.} =
  if value < 0: -1
  elif value > 0: 1
  else: 0

proc intRoot*(value: int): int =
  ## Integer square root by Newton iteration. Named away from the banned
  ## floating-point routine on purpose.
  if value <= 0:
    return 0
  var guess = value
  var next = (guess + 1) div 2
  while next < guess:
    guess = next
    next = (guess + value div guess) div 2
  guess

proc distSq*(ax, ay, bx, by: int): int {.inline.} =
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc withinPx*(ax, ay, bx, by, radius: int): bool {.inline.} =
  distSq(ax, ay, bx, by) <= radius * radius

const
  ## tan((k + 0.5) * 2 * pi / 256) * 4096, k = 0 .. 31. Literal integers so no
  ## floating-point routine appears anywhere in the step path.
  BradTanThresh: array[32, int] = [
    50, 151, 252, 353, 454, 556, 659, 763, 867, 973, 1080, 1188, 1298, 1409,
    1523, 1638, 1756, 1876, 1999, 2125, 2254, 2387, 2524, 2665, 2810, 2961,
    3116, 3278, 3446, 3622, 3805, 3997
  ]

  ## Unit vectors per brad, scaled by 1024. Screen y grows downward, so a
  ## direction vector for brad b is (BradX[b], BradY[b]).
  BradX*: array[256, int] = [
     1024,  1024,  1023,  1021,  1019,  1016,  1013,  1009,  1004,   999,
      993,   987,   980,   972,   964,   955,   946,   936,   926,   915,
      903,   891,   878,   865,   851,   837,   822,   807,   792,   775,
      759,   742,   724,   706,   688,   669,   650,   630,   610,   590,
      569,   548,   526,   505,   483,   460,   438,   415,   392,   369,
      345,   321,   297,   273,   249,   224,   200,   175,   150,   125,
      100,    75,    50,    25,     0,   -25,   -50,   -75,  -100,  -125,
     -150,  -175,  -200,  -224,  -249,  -273,  -297,  -321,  -345,  -369,
     -392,  -415,  -438,  -460,  -483,  -505,  -526,  -548,  -569,  -590,
     -610,  -630,  -650,  -669,  -688,  -706,  -724,  -742,  -759,  -775,
     -792,  -807,  -822,  -837,  -851,  -865,  -878,  -891,  -903,  -915,
     -926,  -936,  -946,  -955,  -964,  -972,  -980,  -987,  -993,  -999,
    -1004, -1009, -1013, -1016, -1019, -1021, -1023, -1024, -1024, -1024,
    -1023, -1021, -1019, -1016, -1013, -1009, -1004,  -999,  -993,  -987,
     -980,  -972,  -964,  -955,  -946,  -936,  -926,  -915,  -903,  -891,
     -878,  -865,  -851,  -837,  -822,  -807,  -792,  -775,  -759,  -742,
     -724,  -706,  -688,  -669,  -650,  -630,  -610,  -590,  -569,  -548,
     -526,  -505,  -483,  -460,  -438,  -415,  -392,  -369,  -345,  -321,
     -297,  -273,  -249,  -224,  -200,  -175,  -150,  -125,  -100,   -75,
      -50,   -25,     0,    25,    50,    75,   100,   125,   150,   175,
      200,   224,   249,   273,   297,   321,   345,   369,   392,   415,
      438,   460,   483,   505,   526,   548,   569,   590,   610,   630,
      650,   669,   688,   706,   724,   742,   759,   775,   792,   807,
      822,   837,   851,   865,   878,   891,   903,   915,   926,   936,
      946,   955,   964,   972,   980,   987,   993,   999,  1004,  1009,
     1013,  1016,  1019,  1021,  1023,  1024
  ]

  BradY*: array[256, int] = [
        0,   -25,   -50,   -75,  -100,  -125,  -150,  -175,  -200,  -224,
     -249,  -273,  -297,  -321,  -345,  -369,  -392,  -415,  -438,  -460,
     -483,  -505,  -526,  -548,  -569,  -590,  -610,  -630,  -650,  -669,
     -688,  -706,  -724,  -742,  -759,  -775,  -792,  -807,  -822,  -837,
     -851,  -865,  -878,  -891,  -903,  -915,  -926,  -936,  -946,  -955,
     -964,  -972,  -980,  -987,  -993,  -999, -1004, -1009, -1013, -1016,
    -1019, -1021, -1023, -1024, -1024, -1024, -1023, -1021, -1019, -1016,
    -1013, -1009, -1004,  -999,  -993,  -987,  -980,  -972,  -964,  -955,
     -946,  -936,  -926,  -915,  -903,  -891,  -878,  -865,  -851,  -837,
     -822,  -807,  -792,  -775,  -759,  -742,  -724,  -706,  -688,  -669,
     -650,  -630,  -610,  -590,  -569,  -548,  -526,  -505,  -483,  -460,
     -438,  -415,  -392,  -369,  -345,  -321,  -297,  -273,  -249,  -224,
     -200,  -175,  -150,  -125,  -100,   -75,   -50,   -25,     0,    25,
       50,    75,   100,   125,   150,   175,   200,   224,   249,   273,
      297,   321,   345,   369,   392,   415,   438,   460,   483,   505,
      526,   548,   569,   590,   610,   630,   650,   669,   688,   706,
      724,   742,   759,   775,   792,   807,   822,   837,   851,   865,
      878,   891,   903,   915,   926,   936,   946,   955,   964,   972,
      980,   987,   993,   999,  1004,  1009,  1013,  1016,  1019,  1021,
     1023,  1024,  1024,  1024,  1023,  1021,  1019,  1016,  1013,  1009,
     1004,   999,   993,   987,   980,   972,   964,   955,   946,   936,
      926,   915,   903,   891,   878,   865,   851,   837,   822,   807,
      792,   775,   759,   742,   724,   706,   688,   669,   650,   630,
      610,   590,   569,   548,   526,   505,   483,   460,   438,   415,
      392,   369,   345,   321,   297,   273,   249,   224,   200,   175,
      150,   125,   100,    75,    50,    25
  ]

  ## Eight compass directions, scaled by 100, used by the unstick rotation.
  DirTable*: array[8, array[2, int]] = [
    [100, 0], [71, -71], [0, -100], [-71, -71],
    [-100, 0], [-71, 71], [0, 100], [71, 71]
  ]

proc octantBrads(small, large: int): int =
  ## Angle in brads (0 .. 32) of a first-octant direction, 0 <= small <= large.
  if large == 0:
    return 0
  let ratio = small * 4096 div large
  var brads = 0
  for k in 0 ..< 32:
    if ratio >= BradTanThresh[k]:
      brads = k + 1
    else:
      break
  brads

proc bearingBrads*(dx, dy: int): int =
  ## 256 brads per turn, 0 = east, counter-clockwise, screen y downward.
  let ux = dx
  let uy = -dy
  if ux == 0 and uy == 0:
    return 0
  let ax = abs(ux)
  let ay = abs(uy)
  let quadrant =
    if ax >= ay: octantBrads(ay, ax)
    else: 64 - octantBrads(ax, ay)
  var brads =
    if ux >= 0 and uy >= 0: quadrant
    elif ux < 0 and uy >= 0: 128 - quadrant
    elif ux < 0: 128 + quadrant
    else: 256 - quadrant
  ((brads mod 256) + 256) mod 256

proc bradDelta*(a, b: int): int =
  ## Signed shortest turn from brad `a` to brad `b`, in -128 .. 127.
  var d = ((b - a) mod 256 + 256) mod 256
  if d > 128:
    d -= 256
  d

proc turnToward*(current, wanted, rate: int): int =
  let d = bradDelta(current, wanted)
  let step = clamp(d, -rate, rate)
  ((current + step) mod 256 + 256) mod 256

proc inCone*(cx, cy, facing, halfBrads, reach, px, py: int): bool =
  ## Body-centre membership in a cone: squared reach plus a brad comparison,
  ## no trigonometry.
  if distSq(cx, cy, px, py) > reach * reach:
    return false
  if cx == px and cy == py:
    return true
  let bearing = bearingBrads(px - cx, py - cy)
  abs(bradDelta(facing, bearing)) <= halfBrads

proc scaleToLength*(dx, dy, length: int): (int, int) =
  ## Integer unit vector scaled to `length`. Never a floating-point divide.
  let d = intRoot(dx * dx + dy * dy)
  if d == 0:
    return (0, 0)
  (dx * length div d, dy * length div d)

proc clampIntoPit*(x, y: int): (int, int) =
  ## Any point further than ClampRadius from the pit centre is pulled ONTO or
  ## inside that circle. The shrink loop is not decoration: `scaleToLength`
  ## floors its integer square root, so scaling straight to ClampRadius can
  ## land a pixel or two outside it on a diagonal, and "clamped into the pit"
  ## has to mean exactly that.
  let dx = x - PitCx
  let dy = y - PitCy
  if dx * dx + dy * dy <= ClampRadius * ClampRadius:
    return (x, y)
  var target = ClampRadius
  while target > 0:
    let (ux, uy) = scaleToLength(dx, dy, target)
    if ux * ux + uy * uy <= ClampRadius * ClampRadius:
      return (PitCx + ux, PitCy + uy)
    target.dec
  (PitCx, PitCy)
