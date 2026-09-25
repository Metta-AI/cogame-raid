## The raid game server: the Coworld game contract over mummy.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/player              - seat page
##   GET /client/global              - spectator page
##   GET /client/replay              - the broadcast replay page
##   GET /client/<asset>             - chrome_common.js, broadcast_core.js
##   GET /replay-data                - the recorded replay JSON (replay mode)
##   WS  /player?slot=N&token=T      - the player protocol
##   WS  /global                     - spectator snapshots
##
## Player protocol (raid.player.v2), JSON text frames:
##   player -> game: {"type":"register","kind":str,"scripted":str|null,
##                    "policy":str}   on connect
##   game -> player: {"type":"welcome","protocol":"raid.player.v2","slot":N,
##                    "alias":str,"turn_seconds":float}
##                   {"type":"decision","id":N,"view":{...},
##                    "system":str,"retry":bool,"timeout_seconds":N}
##   player -> game: {"type":"action","id":N,"action":{...}} or
##                   {"type":"action","id":N,"cause":str,"error":str}
##                   {"type":"turn","turn":N,"tick":T,"phase":P,"role":str,
##                    "view":{...},"order_source":"llm"|"scripted"|"fallback"}
##                   {"done":true,"result":{...}}
##
## The game owns visibility, timing, order repair and fallback. The player
## owns its policy and any model credentials.

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import curly
import mummy
import mummy/routers
import types, config, state, sim, baselines, broadcast, scoring,
  replay, engine, llm, orders, labels

const
  DoneBroadcastSeconds = 3.0
  PlayerProtocol = "raid.player.v2"

type
  ServerState = object
    kinds: seq[string]
    scripted: seq[ScriptKind]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    requestIds: seq[int]
    replies: seq[JsonNode]
    unavailable: seq[bool]
    globalSockets: HashSet[WebSocket]
    snapshot: string
    seats: int
    started: bool
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  replayPayload: string
  eventsSinkPath: string
  metricsSinkPath: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc connectedFlags(): seq[bool] =
  result = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    result[slot] = shared.playerSockets.hasKey(slot)

proc refreshSnapshotLocked() =
  shared.snapshot = $globalSnapshot(gameSim, connectedFlags())
  for socket in shared.globalSockets:
    socket.send(shared.snapshot)

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform polls COGAME_PLAYER_FAILURE_URI so a lobby no-show is
  ## charged to the seat that caused it. Best effort, and a no-op off-platform.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "raid: player-failure declaration failed: ", error.msg

proc requireFileUri*(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    raise newException(RaidError, name & " must be a file:// path, got: " & uri)
  uri[7 .. ^1]

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc pushTurnFrames() =
  ## Post-order informational frame. A dead seat gets one frame with
  ## `you.alive == false` and nothing further until `done`.
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= gameSim.cogs.len:
      continue
    try:
      socket.send($ %*{
        "type": "turn", "turn": gameSim.turn, "tick": gameSim.tick,
        "phase": gameSim.boss.phase,
        "role": $gameSim.cogs[slot].role,
        "view": seatView(gameSim, slot),
        "order_source": $gameSim.orderSources[slot]
      })
    except CatchableError:
      discard

proc broadcastDone(results: JsonNode) =
  ## Bounded at DoneBroadcastSeconds per seat, then we move on: the artifacts
  ## matter more than a slow reader. The budget is ENFORCED, not just measured
  ## - each seat adds 3.0 s to the allowance and a seat whose turn comes up
  ## after the allowance is already spent is skipped, so the whole broadcast
  ## can never hold the artifact writes for more than seats x 3.0 s.
  let payload = $ %*{"done": true, "result": results}
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += DoneBroadcastSeconds
    if epochTime() > allowance:
      echo "raid: done broadcast is past its ", DoneBroadcastSeconds,
        "s-per-seat budget; skipping slot ", slot
      continue
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "raid: done frame to slot ", slot, " failed: ", error.msg
    if epochTime() > allowance:
      echo "raid: done frame to slot ", slot, " exceeded its ",
        DoneBroadcastSeconds, "s budget; moving on"

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  let eventsPath = eventsSinkPath
  let metricsPath = metricsSinkPath
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = resultsJson(gameSim)
    replayData = replayBytes(gameSim)
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastDone(results)
    refreshSnapshotLocked()
  echo "raid: writing results and replay (", replayData.len, " bytes)"
  ## The REPLAY first, then the results: the hosted worker treats results.json
  ## as the end of the episode and tears the pods down when it appears, so a
  ## replay written after it can be lost. Same order as the starter
  ## (`src/ctf/server.nim:1940-1956`).
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  if eventsPath.len > 0:
    try:
      writeFile(eventsPath, $gameSim.events.toJson())
    except CatchableError as error:
      echo "raid: event sink write failed: ", error.msg
  if metricsPath.len > 0:
    try:
      writeFile(metricsPath, $ %*{
        "ticks": gameSim.tick, "turns": gameSim.turn,
        "events": gameSim.events.records.len,
        "keyframes": gameSim.keyframes.len
      })
    except CatchableError as error:
      echo "raid: metrics sink write failed: ", error.msg
  echo "raid: episode complete (", gameSim.reason, "/", gameSim.endRule,
    ") after ", gameSim.tick, " ticks"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its register frame.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = false
      withLock stateLock:
        allRegistered = true
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      shared.started = true
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## A seat that never connects does not end the episode: its cog is
          ## driven by the stalwart baseline for the whole encounter.
          shared.scripted[slot] = skStalwart
          shared.kinds[slot] = "scripted"
        gameSim.policyKinds[slot] = shared.kinds[slot]
      echo "raid: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
      refreshSnapshotLocked()
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "stalwart baseline")

    var kinds: seq[ScriptKind]
    withLock stateLock:
      kinds = shared.scripted

    proc now(): float {.closure.} = epochTime() - gameStart

    proc decide(view: Sim, seats: seq[int]): seq[Decision] {.closure.} =
      let started = epochTime()
      result = newSeq[Decision](seats.len)
      var pending: seq[int]
      for index, seat in seats:
        if kinds[seat] != skNone:
          result[index] = Decision(order: scriptedOrder(view, seat, kinds[seat]),
            source: osScripted)
        else:
          pending.add(index)
      for attempt in 0 .. 1:
        if pending.len == 0:
          break
        var sent: seq[int]
        let timeout = if attempt == 0:
          deadlineSeconds(config.llmAttemptSeconds)
        else:
          deadlineSeconds(config.llmRetrySeconds)
        withLock stateLock:
          for index in pending:
            let seat = seats[index]
            if shared.unavailable[seat] or not shared.registered[seat] or
                not shared.playerSockets.hasKey(seat):
              result[index] = Decision(
                order: scriptedOrder(view, seat, skStalwart),
                source: osFallback, attempts: attempt + 1,
                cause: (if shared.unavailable[seat]: fcNoCreds else: fcTransport),
                detail: (if shared.unavailable[seat]: "no credentials"
                         else: "player disconnected"))
              continue
            let id = view.turn * 2 + attempt + 1
            shared.requestIds[seat] = id
            shared.replies[seat] = nil
            try:
              shared.playerSockets[seat].send($ %*{
                "type": "decision", "id": id, "slot": seat,
                "view": seatView(view, seat),
                "system": SystemPrompt, "retry": attempt > 0,
                "timeout_seconds": timeout
              })
              sent.add(index)
            except CatchableError:
              result[index] = Decision(
                order: scriptedOrder(view, seat, skStalwart),
                source: osFallback, attempts: attempt + 1,
                cause: fcTransport, detail: "player socket send failed")
        let deadline = epochTime() + timeout.float
        while sent.len > 0 and epochTime() < deadline:
          var waiting = false
          withLock stateLock:
            for index in sent:
              if shared.replies[seats[index]] == nil:
                waiting = true
          if not waiting:
            break
          sleep(10)
        var retry: seq[int]
        for index in sent:
          let seat = seats[index]
          var reply: JsonNode
          withLock stateLock:
            reply = shared.replies[seat]
            shared.requestIds[seat] = 0
          if reply == nil:
            result[index] = Decision(
              order: scriptedOrder(view, seat, skStalwart),
              source: osFallback, attempts: attempt + 1,
              cause: fcTimeout, detail: "player decision timed out")
            retry.add(index)
          elif reply.hasKey("cause"):
            let cause = reply["cause"].getStr()
            let fallbackCause = case cause
              of "no_credentials": fcNoCreds
              of "parse_error": fcParse
              else: fcTransport
            result[index] = Decision(
              order: scriptedOrder(view, seat, skStalwart),
              source: osFallback, attempts: attempt + 1,
              cause: fallbackCause,
              detail: runeCap(reply{"error"}.getStr(), MaxDetailRunes))
            if fallbackCause == fcNoCreds:
              withLock stateLock:
                shared.unavailable[seat] = true
            else:
              retry.add(index)
          else:
            try:
              let raw = parseOrder(reply["action"], view.cogs[seat].role)
              result[index] = Decision(order: repairOrder(view, seat, raw),
                source: osLlm, attempts: attempt + 1)
            except CatchableError as error:
              result[index] = Decision(
                order: scriptedOrder(view, seat, skStalwart),
                source: osFallback, attempts: attempt + 1,
                cause: fcParse,
                detail: runeCap(error.msg, MaxDetailRunes))
              retry.add(index)
        pending = retry
      let latency = int((epochTime() - started) * 1000.0)
      for i in 0 ..< result.len:
        if result[i].source != osScripted:
          result[i].latencyMs = latency

    proc onTurn(view: Sim) {.closure.} =
      withLock stateLock:
        pushTurnFrames()
        refreshSnapshotLocked()
      echo "raid: turn ", gameSim.turn, " tick ", gameSim.tick,
        " boss ", gameSim.boss.hp, "/", gameSim.boss.maxHp,
        " alive ", gameSim.aliveCount(), " at ", int(now()), "s"

    runEncounter(gameSim, decide, now, kinds, onTurn)
    finishEpisode(runtimeConfig)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "replay_broadcast.html",
      "text/html; charset=utf-8")

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "player.html",
      "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "global.html",
      "text/html; charset=utf-8")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, replayPayload)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "raid: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "alias": aliasOf(slot),
        "turn_seconds": gameSim.config.turnTicks.float / TargetFps.float
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      if shared.snapshot.len > 0:
        websocket.send(shared.snapshot)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "action":
          withLock stateLock:
            if shared.requestIds[slot] != 0 and
                payload{"id"}.getInt() == shared.requestIds[slot]:
              shared.replies[slot] = payload
          return
        if payload{"type"}.getStr() != "register":
          return
        let kind = payload["kind"].getStr()
        if kind notin ["scripted", "prompt", "jev"]:
          raise newException(RaidError, "unknown policy kind")
        let node = payload{"scripted"}
        let scripted =
          if node == nil or node.kind == JNull: skNone
          elif node.kind == JBool:
            (if node.getBool(): skStalwart else: skNone)
          else: parseScriptKind(node.getStr())
        if kind == "scripted" and scripted == skNone or
            kind != "scripted" and scripted != skNone:
          raise newException(RaidError, "policy kind and baseline disagree")
        let policy = runeCap(payload{"policy"}.getStr(), MaxPolicyLabelRunes)
        withLock stateLock:
          shared.kinds[slot] = kind
          shared.scripted[slot] = scripted
          shared.policies[slot] = policy
          shared.registered[slot] = true
          shared.everRegistered[slot] = true
        echo "raid: slot ", slot, " registered as ", kind
      except CatchableError as error:
        echo "raid: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
          ## A seat that drops keeps playing: its order source degrades to
          ## the stalwart baseline and revives on reconnect.
          if shared.everRegistered[slot] and shared.scripted[slot] == skNone:
            shared.registered[slot] = false
        shared.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: hold the recorded replay for /replay-data and serve the
  ## broadcast page off the identical bundle the static viewer uses.
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "raid: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  ## Only the tests use this: the hosted container exits with the episode.
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(RaidError,
      "tokens must name exactly num_agents seats")
  ## Load the arena and build every render-independent cache BEFORE the
  ## listener opens: a viewer's first-message clock starts at its connect.
  ## file:// ONLY for the two optional sinks, and loudly rejected otherwise:
  ## the dispatcher writes these as workdir paths and the runner uploads the
  ## files afterwards, so an http target means the contract changed.
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  metricsSinkPath = requireFileUri("COGAME_METRICS_URI")
  let bakeStart = epochTime()
  gameSim = initSim(config)
  echo "raid: arena baked in ",
    int((epochTime() - bakeStart) * 1000.0), " ms"
  shared.seats = config.numAgents
  shared.kinds = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  shared.requestIds = newSeq[int](shared.seats)
  shared.replies = newSeq[JsonNode](shared.seats)
  shared.unavailable = newSeq[bool](shared.seats)
  shared.snapshot = $globalSnapshot(gameSim, newSeq[bool](shared.seats))

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "raid: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
