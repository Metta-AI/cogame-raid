## Raid player: a policy is just a prompt.
##
## The player container is deliberately thin. It connects, sends ONE register
## frame carrying its prompt (or its baseline name), and thereafter only
## receives: every decision is made inside the game server, which sends this
## seat's prompt plus its view to Claude once every five seconds, batched with
## the other four seats.
##
## PLAYER_SCRIPTED=stalwart (or 1) registers the seat as the built-in stalwart
## baseline instead; PLAYER_SCRIPTED=greenhorn as the weaker one. The server
## plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <raid-image> --name my-raid \
##     --run /bin/raid-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky

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
  if prompt.strip().len == 0 and scripted.len == 0:
    prompt = DefaultPrompt
  let policy = getEnv("PLAYER_POLICY_LABEL")

  proc registerFrame(): string =
    $ %*{
      "type": "register",
      "prompt": prompt,
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
  echo "raid player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  while true:
    let received = socket.receiveMessage()
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
      else:
        discard
    except CatchableError as error:
      echo "raid player: ignoring bad frame: ", error.msg
  socket.close()
  quit(0)
