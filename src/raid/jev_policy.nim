## Jev selects a complete Raid order from the ordinary private seat view.
import std/[json, os, strutils]
import curly

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, choices: JsonNode): string =
  if answer["type"].getStr() != "choice" or
      answer["probabilities"].len != choices.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned an invalid choice")
  var best = -1.0
  var total = 0.0
  for choice, probability in answer["probabilities"].pairs:
    if not choices.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > choices.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevOrder*(view: JsonNode, slot, timeoutSeconds: int): JsonNode =
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let endpoint = if sidecar.len > 0: sidecar
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model = if sidecar.len > 0: getEnv("BEDROCK_MODEL")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key = if sidecar.len > 0: "" else: getEnv("TYPESAFE_API_KEY").strip()
  let role = view["you"]["role"].getStr()
  let intents = case role
    of "tank": %*{
      "tank_boss": "Hold boss threat and face the cleave away from allies.",
      "taunt": "Recover boss threat when another cog is targeted.",
      "pick_up_adds": "Gather crawlers that threaten the raid.",
      "kite": "Move away while retaining threat.",
      "soak": "Stand in a crucible pour when needed.",
      "wait": "Conserve actions for this order."
    }
    of "healer": %*{
      "heal_lowest": "Heal the lowest-health ally.",
      "heal_target": "Focus healing on a chosen ally.",
      "shield_target": "Shield a chosen ally before damage.",
      "conserve": "Regenerate mana while everyone is safe.",
      "soak": "Stand in a crucible pour when needed.",
      "wait": "Conserve actions for this order."
    }
    else: %*{
      "burn_boss": "Damage SMELTER-9.",
      "kill_adds": "Remove crawlers before they empower the boss.",
      "interrupt": "Interrupt the boss's Overload cast.",
      "assist_target": "Attack a chosen ally's target.",
      "soak": "Stand in a crucible pour when needed.",
      "wait": "Conserve actions for this order."
    }
  let stations = %*{
    "melee": "Fight near the target.",
    "ranged": "Fight 260 pixels from the boss.",
    "spread": "Keep space from allies.",
    "edge": "Move to the pit rim.",
    "point": "Move to the north tank point [617,180].",
    "soak": "Move to a live crucible pour."
  }
  let reactions = %*{
    "dodge": "Leave dangerous telegraphs.",
    "hold": "Hold position through telegraphs.",
    "soak": "Enter a pour circle.",
    "spread": "Spread away from allies."
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $slot
  let body = %*{
    "model": model,
    "state": "Choose one complete order for your dealt role against SMELTER-9 " &
      "from this private view. Coordinate via the visible callouts.\n" & $view,
    "questions": {
      "intent": {"type": "choice", "instructions": "Choose a legal role intent.",
        "criteria": intents},
      "station": {"type": "choice", "instructions": "Choose a station.",
        "criteria": stations},
      "on_telegraph": {"type": "choice",
        "instructions": "Choose the pre-authorised telegraph reaction.",
        "criteria": reactions}
    }
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  let intent = bestChoice(answers["intent"], intents)
  let station = bestChoice(answers["station"], stations)
  let reaction = bestChoice(answers["on_telegraph"], reactions)
  var target = "boss"
  if intent in ["heal_target", "shield_target"]:
    var lowest = 2.0
    for cog in view["raid"]:
      if cog["alive"].getBool():
        let ratio = cog["hp"].getInt().float / cog["max_hp"].getInt().float
        if ratio < lowest:
          lowest = ratio
          target = cog["alias"].getStr()
  elif intent == "kill_adds" and view["adds"].len > 0:
    target = view["adds"][0]["id"].getStr()
  result = %*{
    "intent": intent, "target": target, "station": station,
    "point": [617, 180], "on_telegraph": reaction,
    "note": "Jev order", "say": ""
  }
