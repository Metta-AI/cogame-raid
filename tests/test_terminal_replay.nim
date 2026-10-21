import std/[json, os]
import support/[helpers, terminal_fixture]
import raid/polyworld_replay

proc checkFixture(fixture: JsonNode) =
  let proof = verifyTerminalFixture(fixture)
  let summary = proof["summary"]
  let results = fixture["replay"]["results"]
  checkEq(summary["kill"], results["kill"], "kill attribution")
  checkEq(summary["wipe"], results["wipe"], "wipe attribution")
  checkEq(summary["score"], results["scores"][0], "score recomputed")
  checkEq(proof["control_bytes"].getInt(),
    summary["terminal_tick"].getInt() * Seats * ControlBytesPerCog,
    "no extra terminal controls")
  checkEq(results["charged_seconds"].getFloat(),
    chargedSeconds(summary["end_rule"].getStr(),
      results["enrage_seconds"].getFloat(), results["elapsed_seconds"].getFloat()),
    "wipe charged full enrage; kill charged actual duration")
  if not summary["kill"].getBool():
    var forged = parseJson($fixture["replay"])
    forged["results"]["kill"] = %true
    forged["results"]["end_rule"] = %"kill"
    var rejected = false
    try: discard loadPresentationReplay(forged)
    except RaidError: rejected = true
    check(rejected, "invented victory metadata rejected, not victory coverage")

let retained = getEnv("RAID_TERMINAL_FIXTURES")
if retained.len == 0:
  checkFixture(recordTerminalFixture(TerminalSeeds[0], sharedArena))
else:
  for seed in TerminalSeeds:
    checkFixture(parseFile(retained / ("seed-" & $seed & ".fixture.json")))
echo "test_terminal_replay: authoritative terminal, scoring and no-extra-frame checks hold"
