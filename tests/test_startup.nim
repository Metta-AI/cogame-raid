## Startup behaviour: the game binary refuses a broken runtime contract with a
## clean one-line message and no traceback, and the player binary gives up
## quietly on an unreachable websocket.

import std/[os, osproc, streams, strtabs, strutils]
import support/helpers

proc buildBinary(source, output: string): string =
  let binary = getTempDir() / output
  if fileExists(binary):
    removeFile(binary)
  let command = "nim c --hints:off --path:src -o:" & quoteShell(binary) &
    " " & quoteShell(source)
  let (log, code) = execCmdEx(command)
  if code != 0:
    echo log
    quit("could not build " & source, 1)
  binary

proc runWith(binary: string, env: openArray[(string, string)],
    args: openArray[string] = []): tuple[output: string, code: int] =
  var table = newStringTable()
  for pair in env:
    table[pair[0]] = pair[1]
  let process = startProcess(binary, args = @args, env = table,
    options = {poStdErrToStdOut})
  let stream = process.outputStream
  var output = ""
  discard process.waitForExit(60_000)
  output = stream.readAll()
  let code = process.peekExitCode()
  process.close()
  (output, code)

proc testGameRefusesAMissingConfig() =
  let binary = buildBinary("src/raid.nim", "raid-startup-test")
  let outcome = runWith(binary, [("PATH", getEnv("PATH"))])
  checkEq(outcome.code, 2, "exit 2 when COGAME_CONFIG_URI is missing")
  check("COGAME_CONFIG_URI" in outcome.output,
    "with a message that names the missing variable")
  check("Traceback" notin outcome.output, "and no traceback")
  checkEq(outcome.output.strip().splitLines().len, 1,
    "one clean line: " & outcome.output.strip())
  done("/bin/raid exits 2 on a missing config")

proc testGameRefusesABadConfig() =
  let binary = getTempDir() / "raid-startup-test"
  let bad = getTempDir() / "raid-bad-config.json"
  writeFile(bad, """{"tokens": ["a"], "players": [{"name": "solo"}], "num_agents": 1}""")
  let outcome = runWith(binary, [
    ("PATH", getEnv("PATH")),
    ("COGAME_CONFIG_URI", "file://" & bad)])
  checkEq(outcome.code, 2, "exit 2 on a config the game cannot honour")
  check("num_agents" in outcome.output,
    "naming the problem: " & outcome.output.strip())
  check("Traceback" notin outcome.output, "and no traceback")
  removeFile(bad)
  done("/bin/raid exits 2 on an invalid config")

proc testHelp() =
  let binary = getTempDir() / "raid-startup-test"
  let outcome = runWith(binary, [("PATH", getEnv("PATH"))], ["--help"])
  checkEq(outcome.code, 0, "--help exits 0")
  check("Coworld runtime options" in outcome.output, "and prints the options")
  done("--help works")

proc testPlayerGivesUpQuietly() =
  let binary = buildBinary("src/raid_player.nim", "raid-player-startup-test")
  let outcome = runWith(binary, [
    ("PATH", getEnv("PATH")),
    ("COWORLD_PLAYER_WS_URL", "ws://127.0.0.1:9/player?slot=0&token=x"),
    ("PLAYER_SCRIPTED", "stalwart")])
  checkEq(outcome.code, 0,
    "the player exits 0 on an unreachable url after its bounded retry")
  check("giving up" in outcome.output,
    "saying so: " & outcome.output.strip())
  check("Traceback" notin outcome.output, "and with no traceback")
  done("the player gives up quietly on an unreachable websocket")

proc testPlayerNeedsAUrl() =
  let binary = getTempDir() / "raid-player-startup-test"
  let outcome = runWith(binary, [("PATH", getEnv("PATH"))])
  checkEq(outcome.code, 1, "no COWORLD_PLAYER_WS_URL is an error")
  check("COWORLD_PLAYER_WS_URL" in outcome.output, "that names the variable")
  done("the player needs a websocket url")

when isMainModule:
  testGameRefusesAMissingConfig()
  testGameRefusesABadConfig()
  testHelp()
  testPlayerGivesUpQuietly()
  testPlayerNeedsAUrl()
  echo "test_startup: both entrypoints fail cleanly"
