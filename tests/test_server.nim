## The websocket and HTTP contract, against a real mummy server on a real
## port. The episode itself is kept from starting by a long connect timeout,
## so the test owns the process lifetime.

import std/[json, net, options, os, strutils, times]
import curly
import whisky
import support/helpers
import bitworld/runtime
import raid/server

const Port = 18731

var serverThread: Thread[GameConfig]

proc serve(config: GameConfig) {.thread.} =
  {.gcsafe.}:
    var runtimeConfig = RuntimeConfig(host: "127.0.0.1", port: Port)
    runtimeConfig.resultsUri = "file://" & (getTempDir() /
      "raid-server-test-results.json")
    runtimeConfig.replayUri = "file://" & (getTempDir() /
      "raid-server-test-replay.json")
    runGameServer(config, runtimeConfig)

proc waitForHealth(curl: Curly): bool =
  for attempt in 0 ..< 100:
    try:
      let response = curl.get("http://127.0.0.1:" & $Port & "/healthz", timeout = 2)
      if response.code == 200 and "ok" in response.body:
        return true
    except CatchableError:
      discard
    sleep(100)
  false

proc playerUrl(slot: int, token: string): string =
  "ws://127.0.0.1:" & $Port & "/player?slot=" & $slot & "&token=" & token

proc testFileOnlySinks() =
  putEnv("COGAME_EVENTS_URI", "https://example.com/events.json")
  var caught = false
  try:
    discard requireFileUri("COGAME_EVENTS_URI")
  except RaidError:
    caught = true
  check(caught, "COGAME_EVENTS_URI rejects a non-file scheme loudly")
  putEnv("COGAME_EVENTS_URI", "file:///tmp/events.json")
  checkEq(requireFileUri("COGAME_EVENTS_URI"), "/tmp/events.json",
    "and accepts a file:// path")
  delEnv("COGAME_EVENTS_URI")
  checkEq(requireFileUri("COGAME_EVENTS_URI"), "",
    "an unset sink is simply off")
  putEnv("COGAME_METRICS_URI", "s3://bucket/metrics.json")
  caught = false
  try:
    discard requireFileUri("COGAME_METRICS_URI")
  except RaidError:
    caught = true
  check(caught, "and so does COGAME_METRICS_URI")
  delEnv("COGAME_METRICS_URI")
  done("the two optional sinks are file:// only and fail loudly")

proc testArtifactWritesLandOnFileUris() =
  let path = getTempDir() / "raid-artifact-test.json"
  removeFile(path)
  writeCogameUri("file://" & path, """{"ok":true}""", "application/json",
    "TEST")
  check(fileExists(path), "a file:// artifact write lands on disk")
  checkEq(parseJson(readFile(path)){"ok"}.getBool(), true, "with the payload")
  removeFile(path)
  done("artifact writes land on file:// URIs")

when isMainModule:
  testFileOnlySinks()
  testArtifactWritesLandOnFileUris()

  var episodeConfig = certConfig()
  ## Long enough that the encounter never starts while the test runs: the
  ## game thread would call quit(0) on us.
  episodeConfig.playerConnectTimeoutSeconds = 120.0
  createThread(serverThread, serve, episodeConfig)

  let curl = newCurly()
  check(waitForHealth(curl), "/healthz answers 200 within ten seconds")
  done("/healthz")

  ## A bad token is a 403 and a bad slot is a 403.
  var refused = false
  try:
    let socket = newWebSocket(playerUrl(0, "not-the-token"))
    socket.close()
  except CatchableError:
    refused = true
  check(refused, "a bad token is refused")
  refused = false
  try:
    let socket = newWebSocket(playerUrl(99, "token-0"))
    socket.close()
  except CatchableError:
    refused = true
  check(refused, "and so is a bad slot")
  done("403 on a bad slot or token")

  ## A good token connects and gets the welcome frame.
  let player = newWebSocket(playerUrl(0, "token-0"))
  let welcome = player.receiveMessage()
  check(welcome.isSome, "the seat receives a frame")
  let hello = parseJson(welcome.get().data)
  checkEq(hello["type"].getStr(), "welcome", "the welcome frame")
  checkEq(hello["protocol"].getStr(), "raid.player.v1", "names the protocol")
  checkEq(hello["slot"].getInt(), 0, "and the slot")
  checkEq(hello["alias"].getStr(), "Alpha", "and the alias, never a real name")
  player.send($ %*{"type": "register", "scripted": "stalwart",
    "policy": "test-policy"})
  done("register is accepted")

  ## A second connection on the same slot is a 409.
  var duplicate = false
  try:
    let other = newWebSocket(playerUrl(0, "token-0"))
    other.close()
  except CatchableError:
    duplicate = true
  check(duplicate, "a duplicate connection on a live slot is refused")
  done("409 on a duplicate connection")

  ## /global streams a snapshot immediately.
  let spectator = newWebSocket("ws://127.0.0.1:" & $Port & "/global")
  let snapshot = spectator.receiveMessage()
  check(snapshot.isSome, "the spectator gets a snapshot on connect")
  let state = parseJson(snapshot.get().data)
  checkEq(state["protocol"].getStr(), "raid.global.v1", "the global protocol")
  checkEq(state["game"].getStr(), "raid", "the game name")
  checkEq(state["seats"].len, Seats, "five seats")
  check(state.hasKey("boss") and state.hasKey("events"),
    "the boss and the event transcript")
  spectator.close()
  done("/global streams a snapshot")

  ## The browser page and its assets are served.
  let page = curl.get("http://127.0.0.1:" & $Port & "/client/replay", timeout = 5)
  checkEq(page.code, 200, "/client/replay serves the broadcast page")
  check("bossbar" in page.body, "which is raid's chrome")
  ## The runner's HTTP contract check calls both of these before the episode
  ## starts and fails certification on anything but a 200.
  let seatPage = curl.get(
    "http://127.0.0.1:" & $Port & "/client/player?slot=0&token=token-0",
    timeout = 5)
  checkEq(seatPage.code, 200, "/client/player serves the seat page")
  let spectatorPage = curl.get(
    "http://127.0.0.1:" & $Port & "/client/global", timeout = 5)
  checkEq(spectatorPage.code, 200, "/client/global serves the spectator page")
  let asset = curl.get(
    "http://127.0.0.1:" & $Port & "/client/chrome_common.js", timeout = 5)
  checkEq(asset.code, 200, "/client/<asset> serves the shared chrome")
  let traversal = curl.get(
    "http://127.0.0.1:" & $Port & "/client/..%2Fnimby.lock", timeout = 5)
  check(traversal.code == 404 or traversal.code == 400,
    "and refuses a path-traversal name")
  done("the client routes")

  ## Replay mode is a separate server; assert its data route exists on the
  ## live one as a 404 rather than a crash.
  let replayData = curl.get(
    "http://127.0.0.1:" & $Port & "/replay-data", timeout = 5)
  checkEq(replayData.code, 404, "/replay-data is empty outside replay mode")
  done("/replay-data")

  player.close()
  echo "test_server: the websocket and HTTP contract checks out"
  quit(0)
