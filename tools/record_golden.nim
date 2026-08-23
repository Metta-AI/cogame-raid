import std/[json]
import ../tests/support/helpers
let config = testConfig(seed = 42, maxTicks = 1200, enrage = 960)
let world = runScripted(config, skStalwart)
var digests = newJArray()
for frame in world.keyframes:
  digests.add(%int(frame.digest))
writeFile("tests/fixtures/golden_digests.json", pretty(%*{
  "note": "Keyframe digests for seed 42 over the first 1200 ticks, five stalwart seats. Re-record with tools/record_golden.nim whenever GameVersion moves.",
  "game_version": GameVersion,
  "seed": 42,
  "tick_count": world.tick,
  "digests": digests
}) & "\n")
echo "wrote ", world.keyframes.len, " digests, tick_count=", world.tick
