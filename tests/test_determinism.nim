## THE GATE. Same seed plus the same control bytes must give the same digest at
## every keyframe, in this build and in the emscripten one, plus the
## no-floating-point source guard that keeps it that way.

import std/[json, os, strutils]
import support/helpers

const StepPathModules = [
  "sim.nim", "boss.nim", "telegraphs.nim", "pools.nim", "abilities.nim",
  "combat.nim", "control.nim", "arena.nim", "state.nim", "types.nim",
  "baselines.nim", "orders.nim", "labels.nim", "events.nim"
]

## The modules whose CODE may not mention a float at all. `sim.nim` and
## `state.nim` are excluded because they convert ticks to seconds for the
## event stream, and `orders.nim` because it rejects a non-finite JSON
## coordinate at the parser boundary - none of that is the step.
const IntegerOnlyModules = [
  "boss.nim", "telegraphs.nim", "pools.nim", "abilities.nim", "combat.nim",
  "control.nim", "arena.nim", "types.nim", "labels.nim", "events.nim"
]

const BannedCalls = [
  "sin", "cos", "tan", "atan", "atan2", "arctan", "arctan2", "exp", "ln",
  "log", "pow", "fmod", "hypot", "sqrt", "round", "floor", "ceil"
]

proc srcDir(): string =
  for candidate in ["src/raid", "../src/raid", "../../src/raid"]:
    if dirExists(candidate):
      return candidate
  raise newException(IOError, "src/raid not found from " & getCurrentDir())

proc stripCommentsAndStrings(text: string): string =
  ## Only CODE is checked: a doc comment is allowed to say the word "float",
  ## and it should, because that is where the ban is explained.
  result = newStringOfCap(text.len)
  for rawLine in text.splitLines():
    var line = rawLine
    var inString = false
    var escaped = false
    var kept = ""
    for i in 0 ..< line.len:
      let ch = line[i]
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
        continue
      if ch == '"':
        inString = true
        continue
      if ch == '#':
        break
      kept.add(ch)
    result.add(kept)
    result.add('\n')

proc isIdentChar(ch: char): bool =
  ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc callsRoutine(code, name: string): bool =
  ## `freeScoreAround(` is not a call to `round`, and `octantBrads` is not a
  ## call to `tan`: the match has to start on an identifier boundary.
  let needle = name & "("
  var index = code.find(needle)
  while index >= 0:
    if index == 0 or not isIdentChar(code[index - 1]):
      return true
    index = code.find(needle, index + 1)
  false

proc testNoFloatingPointInTheStepPath() =
  let root = srcDir()
  for name in StepPathModules:
    let path = root / name
    check(fileExists(path), "step-path module present: " & name)
    let code = stripCommentsAndStrings(readFile(path))
    for banned in BannedCalls:
      check(not callsRoutine(code, banned),
        name & " calls the banned floating-point routine `" & banned & "`")
    if name in IntegerOnlyModules:
      for floaty in ["float", "float32", "float64"]:
        check(floaty notin code,
          name & " mentions `" & floaty & "` in code: it is integer-only")
      for literal in ["0.0", "1.0", "0.5", "2.0"]:
        check(literal notin code,
          name & " carries the float literal `" & literal & "`")
  ## And the build scripts must never turn on fast maths.
  for script in ["Dockerfile", "Dockerfile.replay-viewer",
      "replay-viewer/config.nims", "raid.nimble"]:
    for prefix in ["", "../", "../../"]:
      let path = prefix & script
      if fileExists(path):
        check("-ffast-math" notin readFile(path),
          script & " must not enable -ffast-math")
        break
  done("no floating point anywhere in the step path")

proc digestsOf(world: Sim): seq[int] =
  for frame in world.keyframes:
    result.add(int(frame.digest))

proc testSameSeedSameDigests() =
  let config = testConfig()
  let a = runScripted(config, skStalwart)
  let b = runScripted(config, skStalwart)
  checkEq(a.tick, b.tick, "the two runs are the same length")
  check(a.tick > 2000, "and a full encounter, not a stub")
  checkEq(digestsOf(a), digestsOf(b),
    "same seed and same orders give the same digest at every keyframe")
  checkEq(a.controls, b.controls, "and byte-identical control records")
  done("two runs in one process agree at every keyframe")

proc testFreshInstanceAgrees() =
  ## A third run built from a freshly loaded arena rather than the shared one.
  let config = testConfig()
  var world = initSim(config, loadArena("foundry"))
  let kinds = @[skStalwart, skStalwart, skStalwart, skStalwart, skStalwart]
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    scriptedDecisions(view, seats, kinds)
  let clock: Clock = proc (): float = 0.0
  runEncounter(world, decide, clock, kinds, nil)
  let reference = runScripted(config, skStalwart)
  checkEq(digestsOf(world), digestsOf(reference),
    "a fresh sim instance with its own arena bake agrees")
  done("a fresh instance agrees")

proc testOneBitChangesTheDigest() =
  ## Flip one control byte in a re-run and the final digest must move.
  let config = testConfig(maxTicks = 1200, enrage = 960)
  var baseline = newWorld(config)
  var flipped = newWorld(config)
  for slot in 0 ..< Seats:
    baseline.holdStill(slot)
    flipped.holdStill(slot)
  baseline.runTicks(240)
  flipped.runTicks(120)
  flipped.setOrder(2, Order(intent: inBurnBoss, target: "boss",
    station: stEdge, onTelegraph: rxDodge))
  flipped.runTicks(120)
  check(baseline.raidStateDigest() != flipped.raidStateDigest(),
    "one different control byte moves the digest")
  done("a one-bit control change moves the digest")

proc testGoldenFixture() =
  ## tests/fixtures/golden_digests.json pins the digests for seed 42 over the
  ## first 1200 ticks, so any rule change shows up in the diff rather than
  ## silently invalidating every recorded replay.
  let config = testConfig(seed = 42, maxTicks = 1200, enrage = 960)
  let world = runScripted(config, skStalwart)
  var got = newJArray()
  for frame in world.keyframes:
    got.add(%int(frame.digest))
  let golden = parseJson(repoFile("tests/fixtures/golden_digests.json"))
  checkEq(golden{"game_version"}.getStr(), GameVersion,
    "the fixture was recorded against this GameVersion")
  checkEq(golden{"seed"}.getInt(), 42, "the fixture is seed 42")
  checkEq(golden{"tick_count"}.getInt(), world.tick,
    "the fixture ran the same number of ticks")
  checkEq($golden{"digests"}, $got,
    "every pinned keyframe digest still reproduces")
  done("the golden digest fixture reproduces")

when isMainModule:
  testNoFloatingPointInTheStepPath()
  testSameSeedSameDigests()
  testFreshInstanceAgrees()
  testOneBitChangesTheDigest()
  testGoldenFixture()
  echo "test_determinism: the determinism gate holds"
