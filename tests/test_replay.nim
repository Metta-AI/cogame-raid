## An end-to-end episode writing a replay, and the strict UTF-8 parse.

import std/[base64, json, os, strutils, tables, unicode]
import support/helpers

const NonAscii = "sl\u00e5g p\u00f8ur \u{1F525}"
  ## Forced into the event stream so the UTF-8 path is real, not theoretical.

proc runEpisode(): Sim =
  var world = newWorld(certConfig())
  let kinds = @[skStalwart, skStalwart, skStalwart, skStalwart, skStalwart]
  let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
    for seat in seats:
      var decision = Decision(order: scriptedOrder(view, seat, skStalwart),
        source: osScripted)
      if seat == 1:
        decision.order.say = NonAscii
        decision.order.note = "non-ascii on purpose: " & NonAscii
      result.add(decision)
  let clock: Clock = proc (): float = 0.0
  runEncounter(world, decide, clock, kinds, nil)
  world

proc testEndToEnd() =
  let world = runEpisode()
  let dir = getTempDir() / "raid-test-replay"
  createDir(dir)
  let resultsPath = dir / "results.json"
  let replayPath = dir / "replay.json"
  let results = resultsJson(world)
  writeFile(resultsPath, $results)
  writeFile(replayPath, replayBytes(world))

  ## Valid UTF-8 FIRST, and only then JSON: a byte-truncated rune renders in a
  ## browser and dies in a strict parser.
  let raw = readFile(replayPath)
  checkEq(validateUtf8(raw), -1, "the replay bytes are valid UTF-8")
  checkEq(validateUtf8(readFile(resultsPath)), -1,
    "and so are the results bytes")
  check(NonAscii in raw, "the non-ascii say really did reach the replay")
  let doc = parseJson(raw)

  checkEq(doc["protocol"].getStr(), "raid.replay.v1", "protocol")
  checkEq(doc["format_version"].getInt(), 1, "format_version")
  checkEq(doc["game_version"].getStr(), GameVersion, "game_version")
  checkEq(doc["ticks_per_second"].getInt(), TargetFps, "ticks_per_second")
  for key in ["protocol", "format_version", "game_version", "seed", "config",
      "map", "names", "ticks_per_second", "turn_ticks", "tick_count",
      "phases", "controls_b64", "keyframes", "events", "results"]:
    check(doc.hasKey(key), "top-level key present: " & key)
  for key in ["map", "names", "config"]:
    check(doc[key].len > 0, key & " is non-empty")
  for key in ["phases", "keyframes", "events"]:
    check(doc[key].len > 0, key & " is non-empty")

  let tickCount = doc["tick_count"].getInt()
  let controls = decode(doc["controls_b64"].getStr())
  checkEq(controls.len, tickCount * Seats * 4,
    "controls_b64 decodes to exactly tick_count x 5 x 4 bytes")

  let resultsNode = doc["results"]
  check(resultsNode["reason"].getStr() in LegalReasons,
    "results.reason is in the legal enum")
  check(resultsNode["end_rule"].getStr() in LegalEndRules,
    "results.end_rule is in its own")
  checkEq(resultsNode["scores"].len, Seats, "five scores")

  ## The event stream carries the things the phase-60 verifier reads.
  var byType = initTable[string, int]()
  for record in doc["events"]:
    byType.mgetOrPut(record["type"].getStr(), 0) += 1
  for kind in ["encounter_start", "order", "telegraph", "telegraph_resolve",
      "phase_start", "turn_start", "end"]:
    check(byType.getOrDefault(kind, 0) > 0,
      "the event stream contains at least one " & kind)
  let turns = byType.getOrDefault("turn_start", 0)
  check(byType.getOrDefault("order", 0) >= turns,
    "at least one order per turn")

  ## Re-deriving from seed + map + config + the recorded orders reproduces
  ## EVERY keyframe digest, and the control bytes to the byte.
  let rebuilt = rederive(doc)
  checkEq(firstDigestMismatch(doc, rebuilt), -1,
    "every keyframe digest re-derives")
  check(controlsMatch(doc, rebuilt),
    "and the control record re-derives byte for byte")
  removeDir(dir)
  done("an end-to-end episode writes a self-sufficient replay")

proc testReplaySizeIsSane() =
  let world = runScripted(testConfig(), skStalwart)
  let bytes = replayBytes(world)
  check(bytes.len < 4_000_000,
    "a full-length replay stays well under a few megabytes (got " &
    $bytes.len & " bytes)")
  checkEq(validateUtf8(bytes), -1, "and is valid UTF-8")
  discard parseJson(bytes)
  done("a full-length replay is small and parseable")

proc testRejectsAWrongProtocol() =
  let world = runEpisode()
  var doc = replayJson(world, resultsJson(world))
  doc["protocol"] = %"bullwhip.replay.v1"
  var caught = false
  try:
    discard rederive(doc)
  except RaidError:
    caught = true
  check(caught, "a replay with the wrong protocol is rejected")
  done("the re-deriver rejects a foreign protocol")

when isMainModule:
  testEndToEnd()
  testReplaySizeIsSane()
  testRejectsAWrongProtocol()
  echo "test_replay: the replay round-trips and re-derives exactly"
