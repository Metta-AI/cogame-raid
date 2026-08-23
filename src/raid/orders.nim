## The order schema: tolerant parsing, world-aware repair, and the JSON both
## the LLM and the scripted baselines emit.
##
## Parsing is deliberately forgiving (bullwhip's `extractJsonObject` shape):
## markdown fences are stripped, a prose preamble is skipped to the outermost
## balanced object, numbers may arrive as strings, and a target may arrive as
## an integer. What cannot be recovered is repaired against the world instead
## of rejected, so the control layer always has something legal to compile.

import std/[json, strutils, unicode]
import types, state, labels

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first balanced {...} object out of a model response.
  let start = text.find('{')
  if start < 0:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(RaidError,
      "no JSON object in response: " & head.replace("\n", " "))
  var depth = 0
  var inString = false
  var escaped = false
  for i in start ..< text.len:
    let ch = text[i]
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      continue
    if ch == '"':
      inString = true
    elif ch == '{':
      depth.inc
    elif ch == '}':
      depth.dec
      if depth == 0:
        return parseJson(text[start .. i])
  ## Unbalanced: fall back to the last brace so a reply cut off mid-object
  ## still has a chance.
  let stop = text.rfind('}')
  if stop <= start:
    raise newException(RaidError, "unbalanced JSON object in response")
  parseJson(text[start .. stop])

proc parseIntent*(text: string): (Intent, bool) =
  let wanted = runeCap(text, MaxIntentRunes).toLowerAscii()
  for intent in low(Intent) .. high(Intent):
    if $intent == wanted:
      return (intent, true)
  (inWait, false)

proc parseStation*(text: string): (Station, bool) =
  let wanted = runeCap(text, MaxStationRunes).toLowerAscii()
  for station in low(Station) .. high(Station):
    if $station == wanted:
      return (station, true)
  (stRanged, false)

proc parseReaction*(text: string): (Reaction, bool) =
  let wanted = runeCap(text, MaxStationRunes).toLowerAscii()
  for reaction in low(Reaction) .. high(Reaction):
    if $reaction == wanted:
      return (reaction, true)
  (rxDodge, false)

proc canonicalTarget*(node: JsonNode): string =
  ## "" when nothing usable is there. `A<n>` and the five aliases are the only
  ## shapes that survive; an integer 1..8 reads as an add, 0 as slot 0.
  if node == nil:
    return ""
  case node.kind
  of JNull:
    return ""
  of JInt:
    let value = node.getInt()
    if value >= 1 and value <= 8:
      return addName(value)
    if value == 0:
      return aliasOf(0)
    return ""
  of JString:
    let raw = runeCap(node.getStr(), MaxTargetRunes).strip()
    if raw.len == 0:
      return ""
    let lowered = raw.toLowerAscii()
    if lowered == "boss" or lowered == "smelter-9" or lowered == "smelter9":
      return "boss"
    if lowered == "null" or lowered == "none":
      return ""
    let slot = slotOfAlias(raw)
    if slot >= 0:
      return aliasOf(slot)
    if lowered.len >= 2 and lowered[0] == 'a':
      try:
        let n = parseInt(lowered[1 .. ^1])
        if n >= 1 and n <= 99:
          return addName(n)
      except ValueError:
        discard
    try:
      let n = parseInt(lowered)
      if n >= 1 and n <= 8:
        return addName(n)
      if n == 0:
        return aliasOf(0)
    except ValueError:
      discard
    return ""
  else:
    return ""

proc numberFrom(node: JsonNode, fallback: int): int =
  if node == nil:
    return fallback
  case node.kind
  of JInt: node.getInt()
  of JFloat:
    let value = node.getFloat()
    ## Reject a non-finite coordinate rather than letting it into the sim.
    if value != value or value > 1.0e9 or value < -1.0e9: fallback
    else: int(value)
  of JString:
    try: parseInt(node.getStr().strip())
    except ValueError:
      try: int(parseFloat(node.getStr().strip()))
      except ValueError: fallback
  else: fallback

proc parseOrder*(node: JsonNode, role = roleDps): Order =
  ## Shape-level parse only; `repairOrder` does the world-aware half. An
  ## unknown enum value falls to the role's default rather than failing the
  ## reply — only a MISSING intent is unrecoverable, and that is what makes
  ## the retry fire.
  if node == nil or node.kind != JObject:
    raise newException(RaidError, "order must be a JSON object")
  let intentNode = node{"intent"}
  if intentNode == nil or intentNode.kind != JString or
      intentNode.getStr().strip().len == 0:
    raise newException(RaidError, "order has no intent")
  let (intent, intentOk) = parseIntent(intentNode.getStr())
  let (station, stationOk) = parseStation(node{"station"}.getStr())
  let (reaction, _) = parseReaction(node{"on_telegraph"}.getStr())
  result = Order(
    intent: (if intentOk: intent else: defaultIntentFor(role)),
    target: canonicalTarget(node{"target"}),
    station: (if stationOk: station else: defaultStationFor(role)),
    onTelegraph: reaction,
    note: runeCap(node{"note"}.getStr(), MaxNoteRunes),
    say: runeCap(node{"say"}.getStr(), MaxSayRunes)
  )
  let point = node{"point"}
  if point != nil and point.kind == JArray and point.len >= 2:
    result.px = numberFrom(point[0], PitCx)
    result.py = numberFrom(point[1], PitCy)
    result.hasPoint = true

proc orderToJson*(order: Order): JsonNode =
  %*{
    "intent": $order.intent,
    "target": order.target,
    "station": $order.station,
    "point": [order.px, order.py],
    "on_telegraph": $order.onTelegraph,
    "note": order.note,
    "say": order.say
  }

proc entityAlive*(sim: Sim, target: string): bool =
  if target.len == 0:
    return false
  if target == "boss":
    return sim.boss.hp > 0
  let slot = slotOfAlias(target)
  if slot >= 0:
    return sim.cogs[slot].alive
  if target.len >= 2 and target[0] == 'A':
    try:
      let index = sim.addIndexById(parseInt(target[1 .. ^1]))
      return index >= 0 and sim.adds[index].alive
    except ValueError:
      return false
  false

proc naturalTarget*(sim: Sim, slot: int, intent: Intent): string =
  case intent
  of inTankBoss, inBurnBoss, inTaunt, inKite:
    "boss"
  of inPickUpAdds, inKillAdds:
    let index = sim.nearestLivingAdd(sim.cogs[slot].x, sim.cogs[slot].y)
    if index < 0: "" else: addName(sim.adds[index].id)
  of inHealLowest, inHealTarget, inShieldTarget, inConserve:
    let ally = sim.lowestHpAlly()
    if ally < 0: "" else: aliasOf(ally)
  of inAssistTarget:
    let ally = sim.lowestHpAlly(slot)
    if ally < 0: "" else: aliasOf(ally)
  of inInterrupt, inSoak, inWait:
    ""

proc targetLegalFor*(intent: Intent, target: string): bool =
  if target.len == 0:
    return intent in {inInterrupt, inSoak, inWait, inConserve, inHealLowest}
  let isAlly = slotOfAlias(target) >= 0
  var isAdd = false
  if not isAlly and target.len >= 2 and target[0] == 'A':
    try:
      discard parseInt(target[1 .. ^1])
      isAdd = true
    except ValueError:
      isAdd = false
  let isBoss = target == "boss"
  case intent
  of inTankBoss, inBurnBoss, inTaunt, inKite: isBoss
  of inPickUpAdds, inKillAdds: isAdd
  of inHealTarget, inShieldTarget, inAssistTarget: isAlly
  of inHealLowest, inConserve: isAlly
  of inInterrupt, inSoak, inWait: isBoss or isAdd or isAlly

proc requiresTarget*(intent: Intent): bool =
  intent in {inPickUpAdds, inKillAdds, inHealTarget, inShieldTarget,
    inAssistTarget}

proc repairOrder*(sim: Sim, slot: int, raw: Order): Order =
  ## Every violation in the design note's repair table, applied in order.
  result = raw
  let role = sim.cogs[slot].role
  if not intentLegalFor(result.intent, role):
    result.intent = defaultIntentFor(role)
  if not targetLegalFor(result.intent, result.target) or
      (result.target.len > 0 and not sim.entityAlive(result.target)):
    result.target = naturalTarget(sim, slot, result.intent)
  if result.target.len == 0 and requiresTarget(result.intent):
    result.intent = inWait
    result.target = ""
  if not result.hasPoint:
    result.px = sim.cogs[slot].x
    result.py = sim.cogs[slot].y
    result.hasPoint = true
  let clamped = clampIntoPit(result.px, result.py)
  result.px = clamped[0]
  result.py = clamped[1]
  result.note = runeCap(result.note, MaxNoteRunes)
  result.say = runeCap(result.say, MaxSayRunes)

proc validateOrder*(sim: Sim, slot: int, order: Order): string =
  ## "" when the order is legal for this seat and this world; otherwise the
  ## first violation. Used by the bounded-orders test.
  let role = sim.cogs[slot].role
  if not intentLegalFor(order.intent, role):
    return "intent " & $order.intent & " illegal for " & $role
  if order.target.len > 0:
    if not targetLegalFor(order.intent, order.target):
      return "target " & order.target & " illegal for " & $order.intent
    if not sim.entityAlive(order.target):
      return "target " & order.target & " is not alive"
  elif requiresTarget(order.intent):
    return "intent " & $order.intent & " needs a target"
  if not withinPx(order.px, order.py, PitCx, PitCy, ClampRadius):
    return "point outside the pit"
  if order.note.runeLen > MaxNoteRunes:
    return "note over " & $MaxNoteRunes & " runes"
  if order.say.runeLen > MaxSayRunes:
    return "say over " & $MaxSayRunes & " runes"
  ""
