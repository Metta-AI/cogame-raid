## Retain every predeclared attempt outside git; never label a wipe a win.
import std/[json, os]
import raid/[sim, scoring]
import ../tests/support/terminal_fixture

if paramCount() != 1:
  quit("usage: record_terminal_coverage PRIVATE_OUTPUT", 2)
let output = paramStr(1)
createDir(output)
let arena = loadArena("foundry")
var attempts = newJArray()
for seed in TerminalSeeds:
  let fixture = recordTerminalFixture(seed, arena)
  let prefix = output / ("seed-" & $seed)
  writeFile(prefix & ".fixture.json", $fixture)
  writeFile(prefix & ".replay.json", $fixture["replay"])
  let proof = verifyTerminalFixture(fixture)
  writeFile(prefix & ".public.json", $proof["public_replay"])
  var oracle = parseJson($proof)
  oracle.delete("public_replay")
  writeFile(prefix & ".native.json", $oracle)
  attempts.add(%*{"seed": seed, "summary": proof["summary"],
    "terminal_tick": proof["terminal_tick"],
    "terminal_hazards": proof["terminal_hazards"],
    "terminal_interrupts": proof["terminal_interrupts"]})
  echo "RETAINED seed=", seed, " ", proof["summary"]
writeFile(output / "attempts.json", $attempts)
