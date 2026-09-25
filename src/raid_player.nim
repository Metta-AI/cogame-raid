## Raid player: prompt, Jev and scripted policies use one seat socket.
##
## PLAYER_SCRIPTED=stalwart (or 1) registers the seat as the built-in stalwart
## baseline instead; PLAYER_SCRIPTED=greenhorn as the weaker one. The server
## plays scripted baselines deterministically.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <raid-image> --name my-raid \
##     --run /bin/raid-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import curly
import whisky
import raid/[llm, orders, types, jev_policy]

const
  ConnectAttempts = 5
  ConnectBackoffMs = 250
  DefaultPrompt = """
Play the role you were dealt and do not improvise a second plan.
TANK: stand north of the boss at point [617,180] with on_telegraph "hold" so
every cleave points at empty floor, and taunt the moment the boss's target in
your view is not you.
HEALER: station "ranged" with a clear line to the tank, "heal_lowest" while
anyone is under 60% and "conserve" above 75% - your mana pool is a burst
reserve, not a budget. on_telegraph "dodge" always.
DPS: "burn_boss" from station "ranged", on_telegraph "dodge". Say "I interrupt"
on the first turn of phase 2 and hold intent "interrupt" if nobody else claimed
it; switch to "kill_adds" while three or more crawlers are alive. In phase 3,
step into the crucible with intent "soak" if nobody has called it - an unsoaked
crucible makes the boss permanently 20% stronger.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let jev = getEnv("PLAYER_JEV").strip() == "true"
  if prompt.strip().len == 0 and scripted.len == 0 and not jev:
    prompt = DefaultPrompt
  let policy = getEnv("PLAYER_POLICY_LABEL")
  let kind = if scripted.len > 0: "scripted"
    elif jev: "jev"
    else: "prompt"
  let client = if kind == "prompt": newLlmClient()
    else: nil

  proc registerFrame(): string =
    $ %*{
      "type": "register",
      "kind": kind,
      "scripted": scripted,
      "policy": policy
    }

  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "raid player: connect attempt ", attempt, " failed: ", error.msg
      if attempt == ConnectAttempts:
        ## A bounded retry, then leave quietly: the game declares the no-show
        ## itself and plays the seat on the stalwart baseline.
        echo "raid player: giving up on ", url
        quit(0)
      sleep(ConnectBackoffMs * attempt)

  socket.send(registerFrame())
  echo "raid player: registered as ", kind

  while true:
    ## whisky raises rather than returning none on both a close frame and a
    ## half-read one, and mummy's `send` only queues: the game writes its
    ## artifacts and exits, so a seat can lose the socket before its `done`
    ## frame is flushed. The episode is over either way — a player that dies
    ## here exits 1 and fails certification with `player_error`.
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "raid player: connection ended (", error.msg, "), exiting"
      break
    if received.isNone:
      echo "raid player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "raid player: final scores ", payload{"result"}{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "raid player: seated at slot ", payload{"slot"}.getInt(),
          " as ", payload{"alias"}.getStr()
        ## Re-deliver the registration in case the first send raced the
        ## server's slot bookkeeping.
        socket.send(registerFrame())
      of "turn":
        discard
      of "decision":
        var reply = %*{"type": "action", "id": payload["id"]}
        if kind == "prompt" and client.disabled or
            kind == "jev" and not jevConfigured():
          reply["cause"] = %"no_credentials"
          reply["error"] = %"no credentials"
        else:
          try:
            if kind == "jev":
              reply["action"] = chooseJevOrder(payload["view"],
                payload["slot"].getInt(),
                payload["timeout_seconds"].getInt())
            else:
              var user = userPrompt(payload["view"], prompt)
              if payload["retry"].getBool():
                user.add(RetryHint)
              let request = client.requestFor(payload["system"].getStr(), user)
              let response = client.curl.post(request.url, request.headers,
                request.body, payload["timeout_seconds"].getInt())
              reply["action"] = extractJsonObject(
                client.textOf(response, "", request.url))
          except LlmError as error:
            reply["cause"] = %"transport_error"
            reply["error"] = %error.msg
          except RaidError as error:
            reply["cause"] = %"parse_error"
            reply["error"] = %error.msg
          except CatchableError as error:
            reply["cause"] = %"transport_error"
            reply["error"] = %error.msg
        socket.send($reply)
      else:
        discard
    except CatchableError as error:
      echo "raid player: ignoring bad frame: ", error.msg
  socket.close()
  quit(0)
