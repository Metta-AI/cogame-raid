## The scoring formula and its sign.

import support/helpers
import std/[json]

proc scoreOf(removedFrac: float, elapsed: float, endRule: string,
    enrage = 240.0): float =
  let bossMax = 26000
  let removed = int(removedFrac * bossMax.float + 0.5)
  episodeScore(bossMax, bossMax - removed, int(enrage * 24.0),
    int(elapsed * 24.0), endRule)

proc testWorkedExamples() =
  checkNear(scoreOf(1.00, 192.0, "kill"), 1.250, 0.001, "clean kill at 192 s")
  checkNear(scoreOf(1.00, 244.0, "kill"), 0.984, 0.001, "kill 4 s into enrage")
  checkNear(scoreOf(0.71, 150.0, "wipe"), 0.710, 0.001, "wipe at 150 s, 71 %")
  checkNear(scoreOf(0.88, 270.0, "enrage_timeout"), 0.880, 0.001,
    "survived to the hard end at 88 %")
  checkNear(scoreOf(0.44, 130.0, "wall_clock"), 0.440, 0.001,
    "wall-clock deadline at 130 s, 44 %")
  checkNear(scoreOf(0.03, 12.0, "wipe"), 0.030, 0.001,
    "instant faceplant: wipe at 12 s, 3 %")
  done("every worked example reproduces to three decimals")

proc testOnlyAKillIsChargedElapsed() =
  for rule in ["wipe", "enrage_timeout", "wall_clock", "sim_fault",
      "host_error"]:
    checkNear(chargedSeconds(rule, 240.0, 12.0), 240.0, 1e-9,
      rule & " is charged the whole attempt")
  checkNear(chargedSeconds("kill", 240.0, 192.0), 192.0, 1e-9,
    "a kill is charged the seconds it took")
  done("a kill is the only ending charged `elapsed`")

proc testMonotonicity() =
  var previous = -1.0
  for step in 0 .. 20:
    let value = scoreOf(step.float / 20.0, 150.0, "wipe")
    check(value >= previous, "score is monotone increasing in `removed`")
    previous = value
  previous = 1e9
  for step in 1 .. 20:
    let value = scoreOf(1.0, 60.0 + step.float * 10.0, "kill")
    check(value <= previous, "a kill's score decreases with elapsed time")
    previous = value
  done("monotone in removed, and (for kills) decreasing in elapsed")

proc testBoundsAndFloor() =
  checkNear(scoreOf(0.0, 200.0, "wipe"), 0.0, 1e-9,
    "a zero-damage wipe scores exactly 0.0")
  check(scoreOf(1.0, 1.0, "kill") <= 3.0, "the clamp holds at 3.0")
  check(scoreOf(1.0, 1.0, "kill") >= 0.0, "and never goes negative")
  for elapsed in [1.0, 10.0, 100.0, 400.0]:
    for frac in [0.0, 0.5, 1.0]:
      for rule in ["kill", "wipe", "enrage_timeout", "wall_clock",
          "sim_fault", "host_error"]:
        let value = scoreOf(frac, elapsed, rule)
        check(value >= 0.0 and value <= 3.0,
          "score stays in [0, 3] for " & rule)
  done("score is never negative and is clamped at 3.0")

proc testAllFiveSeatsShareTheScore() =
  ## 200 randomised endings, every one of them five identical numbers.
  var rng = initPcg32(20260823)
  for trial in 0 ..< 200:
    var world = newWorld(testConfig(seed = 100 + trial))
    world.boss.hp = rng.below(world.boss.maxHp + 1)
    world.tick = 1 + rng.below(world.config.maxTicks)
    world.deaths = rng.below(6)
    world.reason = "complete"
    world.endRule = ["kill", "wipe", "enrage_timeout"][rng.below(3)]
    let results = resultsJson(world)
    let scores = results["scores"]
    checkEq(scores.len, Seats, "five scores")
    for i in 1 ..< Seats:
      check(scores[i].getFloat() == scores[0].getFloat(),
        "all five entries of results.scores are identical")
    check(scores[0].getFloat() >= 0.0, "and never negative")
  done("results.scores is five copies of one number, 200 randomised endings")

proc testKillScoresAboveOne() =
  var world = newWorld(certConfig())
  world.boss.hp = 0
  world.tick = 600
  world.reason = "complete"
  world.endRule = "kill"
  let score = world.simScore()
  check(score > 1.0,
    "a kill well inside the enrage timer scores above 1.0 (got " &
    $score & ")")
  done("a fast kill scores above 1.0")

when isMainModule:
  testWorkedExamples()
  testOnlyAKillIsChargedElapsed()
  testMonotonicity()
  testBoundsAndFloor()
  testAllFiveSeatsShareTheScore()
  testKillScoresAboveOne()
  echo "test_scoring: the formula and its sign check out"
