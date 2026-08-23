## The grid harness the stalwart baseline's scalar tunables were chosen with.
##
## The four numbers it sweeps - `TankStandDy`, `HealWorthwhileHp`,
## `HealThresholdPct` and `TankPriorityPct` (`src/raid/baselines.nim`) - are
## `{.intdefine.}` constants, so one grid point is one `-d:Name=value` build.
## The harness therefore compiles itself once per point and runs the probe:
##
##   nim r --path:src --path:tests tools/tune_baselines.nim        # the sweep
##   <binary> probe                                                # one point
##
## Objective, in this order:
##   1. the tank's stand must be floor a cog can actually stand on
##      (`arena.canOccupyCog`): every point closer than 35 px to the boss is
##      inside SMELTER-9's own 56 px footprint, so the tank could never arrive;
##   2. the certification fixture must still end in a KILL with the raid
##      standing - a point that cannot certify is worthless whatever it scores;
##   3. mean `simScore` over `Seeds` in the default variant (26 000 hp, the
##      full 6480-tick clock), which is exactly what the league ranks by.
## Ties go to the values already in `src/raid/baselines.nim`, so a re-run
## reports the shipped point unless the sweep can actually beat it.
##
## The sweep is deterministic: every episode is `runScripted`, no clock, no
## network, no randomness beyond the episode seed. Re-run it after any change
## to the baseline or the boss script; it takes a few minutes because each
## point is a fresh release build.

import std/[algorithm, os, osproc, strformat, strutils]
import ../tests/support/helpers

const
  Seeds = [42, 7, 1234, 999, 2718, 31337]
  TankStandDyGrid = [24, 30, 36, 42, 48]
  HealWorthwhileHpGrid = [30, 45, 60]
  HealThresholdPctGrid = [70, 80, 90]
  TankPriorityPctGrid = [35, 45, 55]

type Point = object
  tankStandDy, healWorthwhileHp, healThresholdPct, tankPriorityPct: int
  score: float
  distance: int          ## fields differing from the values in baselines.nim
  legal, certified, incumbent: bool

proc probe() =
  ## One grid point, with the values compiled in. Prints a single line the
  ## driver parses.
  var total = 0.0
  for seed in Seeds:
    total += runScripted(testConfig(seed = seed), skStalwart).simScore()
  let cert = runScripted(certConfig(), skStalwart)
  let certified = cert.reason == "complete" and cert.endRule == "kill" and
    cert.aliveCount() >= 1
  echo &"RESULT score={total / Seeds.len.float:.4f} certified={certified} " &
    &"certScore={cert.simScore():.3f} certTick={cert.tick}"

proc measure(point: var Point, index, total: int) =
  if not point.legal:
    echo &"[{index + 1}/{total}] dy={point.tankStandDy} -> rejected: " &
      "the stand is inside SMELTER-9's footprint, no cog can occupy it"
    return
  let binary = getTempDir() / &"raid_tune_{point.tankStandDy}_" &
    &"{point.healWorthwhileHp}_{point.healThresholdPct}_" &
    &"{point.tankPriorityPct}"
  let build = execCmdEx("nim c -d:release --hints:off --path:src --path:tests " &
    &"-d:TankStandDy={point.tankStandDy} " &
    &"-d:HealWorthwhileHp={point.healWorthwhileHp} " &
    &"-d:HealThresholdPct={point.healThresholdPct} " &
    &"-d:TankPriorityPct={point.tankPriorityPct} " &
    &"-o:{binary} tools/tune_baselines.nim")
  if build.exitCode != 0:
    quit("build failed for " & $point & "\n" & build.output, 1)
  let run = execCmdEx(binary & " probe")
  removeFile(binary)
  if run.exitCode != 0:
    quit("probe failed for " & $point & "\n" & run.output, 1)
  for line in run.output.splitLines():
    if not line.startsWith("RESULT "):
      continue
    for field in line.split(' '):
      let parts = field.split('=', 1)
      if parts.len != 2:
        continue
      case parts[0]
      of "score": point.score = parseFloat(parts[1])
      of "certified": point.certified = parts[1] == "true"
      else: discard
  echo &"[{index + 1}/{total}] dy={point.tankStandDy} " &
    &"worth={point.healWorthwhileHp} thresh={point.healThresholdPct} " &
    &"prio={point.tankPriorityPct} -> score={point.score:.4f} " &
    &"certified={point.certified}"

proc sweep() =
  if not fileExists("tools/tune_baselines.nim"):
    quit("run me from the repo root: nim r --path:src --path:tests " &
      "tools/tune_baselines.nim", 1)
  var points: seq[Point]
  for dy in TankStandDyGrid:
    for worth in HealWorthwhileHpGrid:
      for thresh in HealThresholdPctGrid:
        for prio in TankPriorityPctGrid:
          points.add(Point(tankStandDy: dy, healWorthwhileHp: worth,
            healThresholdPct: thresh, tankPriorityPct: prio,
            legal: sharedArena.canOccupyCog(PitCx, PitCy - dy),
            distance: ord(dy != TankStandDy) +
              ord(worth != HealWorthwhileHp) +
              ord(thresh != HealThresholdPct) + ord(prio != TankPriorityPct),
            incumbent: dy == TankStandDy and worth == HealWorthwhileHp and
              thresh == HealThresholdPct and prio == TankPriorityPct))
  let total = points.len
  for index in 0 ..< total:
    points[index].measure(index, total)
  points.sort(proc (a, b: Point): int =
    if a.legal != b.legal:
      return (if a.legal: -1 else: 1)
    if a.certified != b.certified:
      return (if a.certified: -1 else: 1)
    if a.score != b.score:
      return cmp(b.score, a.score)
    ## Ties go to the point that changes the fewest shipped values, so a
    ## re-run keeps `baselines.nim` unless the sweep can actually beat it.
    cmp(a.distance, b.distance))
  echo "\n== ranked (legal and certified first, then mean score) =="
  for index, point in points:
    if index >= 12:
      echo &"... {total - 12} more"
      break
    echo &"  dy={point.tankStandDy} worth={point.healWorthwhileHp} " &
      &"thresh={point.healThresholdPct} prio={point.tankPriorityPct} " &
      &"score={point.score:.4f} certified={point.certified}" &
      (if point.incumbent: "   <- the values in baselines.nim" else: "")
  echo "\nkept: dy=", points[0].tankStandDy,
    " worth=", points[0].healWorthwhileHp,
    " thresh=", points[0].healThresholdPct,
    " prio=", points[0].tankPriorityPct,
    &" (mean score {points[0].score:.4f})"

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "probe":
    probe()
  else:
    sweep()
