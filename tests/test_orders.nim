## Tolerant parsing and world-aware repair, including the rune-boundary
## truncation that keeps replay bytes parseable.

import std/[json, strutils, unicode]
import curly
import support/helpers
import raid/[orders, llm]

proc parseFor(world: Sim, slot: int, text: string): Order =
  repairOrder(world, slot, parseOrder(extractJsonObject(text),
    world.cogs[slot].role))

proc testProsePrefixedJson() =
  var world = quietWorld()
  let order = world.parseFor(0,
    "Let me think about this. The tank should hold aggro.\n" &
    "{\"intent\": \"tank_boss\", \"target\": \"boss\", \"station\": \"melee\"," &
    " \"on_telegraph\": \"hold\", \"note\": \"holding\", \"say\": \"on it\"}")
  checkEq($order.intent, "tank_boss", "prose before the object is skipped")
  checkEq($order.station, "melee", "and the object still parses")
  done("prose-prefixed JSON")

proc testFencedJson() =
  var world = quietWorld()
  let order = world.parseFor(0,
    "```json\n{\"intent\":\"taunt\",\"target\":\"boss\"}\n```")
  checkEq($order.intent, "taunt", "markdown fences are stripped")
  done("fenced JSON")

proc testNestedObjectIsBalanced() =
  var world = quietWorld()
  let order = world.parseFor(2,
    "{\"intent\":\"burn_boss\",\"extra\":{\"nested\":{\"deep\":1}}," &
    "\"say\":\"ok\"} trailing prose")
  checkEq($order.intent, "burn_boss", "the outermost balanced object is taken")
  checkEq(order.say, "ok", "with its fields intact")
  done("balanced brace matching")

proc testUnknownEnums() =
  var world = quietWorld()
  let tank = world.parseFor(0,
    "{\"intent\":\"do_a_barrel_roll\",\"station\":\"orbit\"," &
    "\"on_telegraph\":\"panic\"}")
  checkEq($tank.intent, "tank_boss", "an unknown intent falls to the role default")
  checkEq($tank.station, "melee", "an unknown station falls to melee for a tank")
  checkEq($tank.onTelegraph, "dodge", "an unknown reaction falls to dodge")
  let healer = world.parseFor(world.healerSlot(),
    "{\"intent\":\"nonsense\",\"station\":\"nonsense\"}")
  checkEq($healer.intent, "heal_lowest", "and to heal_lowest for a healer")
  checkEq($healer.station, "ranged", "and ranged for everyone but the tank")
  done("unknown enum values are repaired, not rejected")

proc testWrongRoleIntent() =
  var world = quietWorld()
  let healer = world.healerSlot()
  let order = world.parseFor(healer, "{\"intent\":\"burn_boss\"}")
  checkEq($order.intent, "heal_lowest",
    "a healer sending a dps intent gets its own default")
  let dps = world.parseFor(2, "{\"intent\":\"heal_lowest\"}")
  checkEq($dps.intent, "burn_boss", "and a dps sending a healer intent")
  let shared = world.parseFor(2, "{\"intent\":\"wait\"}")
  checkEq($shared.intent, "wait", "but `wait` is legal for everyone")
  done("intents legal for another role are repaired")

proc testPointFormsAndClamping() =
  var world = quietWorld()
  let strings = world.parseFor(0,
    "{\"intent\":\"tank_boss\",\"station\":\"point\"," &
    "\"point\":[\"620\",\"330\"]}")
  checkEq((strings.px, strings.py), (620, 330), "numeric strings parse")
  let outside = world.parseFor(0,
    "{\"intent\":\"tank_boss\",\"station\":\"point\",\"point\":[9000,-9000]}")
  check(withinPx(outside.px, outside.py, PitCx, PitCy, ClampRadius),
    "a point outside the pit is pulled onto the clamp circle")
  let missing = world.parseFor(0, "{\"intent\":\"tank_boss\"}")
  checkEq((missing.px, missing.py), (world.cogs[0].x, world.cogs[0].y),
    "a missing point becomes the cog's current position")
  let bogus = world.parseFor(0,
    "{\"intent\":\"tank_boss\",\"station\":\"point\"," &
    "\"point\":[\"north\",\"west\"]}")
  check(withinPx(bogus.px, bogus.py, PitCx, PitCy, ClampRadius),
    "an unparseable point still lands inside the pit")
  done("point forms, clamping and repair")

proc testTargetForms() =
  var world = quietWorld()
  world.adds.add(Add(id: 3, x: PitCx + 100, y: PitCy, hp: AddHp, alive: true,
    target: 0))
  let asInt = world.parseFor(2, "{\"intent\":\"kill_adds\",\"target\":3}")
  checkEq(asInt.target, "A3", "an integer 3 reads as add A3")
  let lower = world.parseFor(2, "{\"intent\":\"kill_adds\",\"target\":\"a3\"}")
  checkEq(lower.target, "A3", "and so does \"a3\"")
  let missingAdd = world.parseFor(2,
    "{\"intent\":\"kill_adds\",\"target\":\"A99\"}")
  checkEq(missingAdd.target, "A3",
    "a target that does not exist becomes the intent's natural target")
  let alias = world.parseFor(world.healerSlot(),
    "{\"intent\":\"heal_target\",\"target\":\"delta\"}")
  checkEq(alias.target, "Delta", "aliases are case-insensitive")
  world.cogs[3].alive = false
  let dead = world.parseFor(world.healerSlot(),
    "{\"intent\":\"heal_target\",\"target\":\"Delta\"}")
  check(dead.target != "Delta", "a dead cog is replaced")
  check(world.entityAlive(dead.target), "by something that is alive")
  done("target forms and repair")

proc testDegradesToWaitWithNoTarget() =
  var world = quietWorld()
  world.adds = @[]
  let order = world.parseFor(2, "{\"intent\":\"kill_adds\"}")
  checkEq($order.intent, "wait",
    "kill_adds with no adds alive degrades to wait")
  done("an intent with no available target degrades to wait")

proc testNoteAndSayCaps() =
  var world = quietWorld()
  let long = "x".repeat(400)
  let order = world.parseFor(0,
    "{\"intent\":\"tank_boss\",\"note\":\"" & long & "\"}")
  checkEq(order.note.runeLen, MaxNoteRunes, "a 400-character note is trimmed")
  done("note and say caps")

proc testRuneBoundaryTruncation() =
  ## The 32nd and 33rd runes of the `say` are 4-byte emoji. Truncation must
  ## land on the RUNE boundary, or the bytes render in a browser and then fail
  ## a strict JSON parser.
  var world = quietWorld()
  let emoji = "\u{1F525}"          ## FIRE, four bytes in UTF-8
  checkEq(emoji.len, 4, "the test emoji really is four bytes")
  let say = "a".repeat(31) & emoji & emoji & "tail"
  checkEq(say.runeLen, 31 + 2 + 4, "the source string is 37 runes")
  let order = world.parseFor(0,
    $ %*{"intent": "tank_boss", "say": say})
  checkEq(order.say.runeLen, MaxSayRunes, "trimmed to exactly 32 runes")
  checkEq(order.say, "a".repeat(31) & emoji,
    "and the 32nd rune is the whole emoji, not two of its bytes")
  checkEq(validateUtf8(order.say), -1, "the result is valid UTF-8")
  ## It must survive %* / $ / parseJson, and being copied into another seat's
  ## callouts.
  let round = parseJson($ %*{"say": order.say})
  checkEq(round["say"].getStr(), order.say, "round-trips through JSON")
  world.pendingSays[0] = order.say
  world.says[1] = world.pendingSays[0]
  let serialised = $ %*{"callouts": [{"alias": "Alpha", "say": world.says[1]}]}
  checkEq(validateUtf8(serialised), -1,
    "and a callout carrying it is still valid UTF-8")
  discard parseJson(serialised)
  done("say truncates on a rune boundary with a 4-byte emoji on the seam")

proc testMissingIntentIsUnrecoverable() =
  var caught = false
  try:
    discard parseOrder(extractJsonObject("{\"say\":\"hello\"}"), roleDps)
  except RaidError:
    caught = true
  check(caught, "an object with no intent is what makes the retry fire")
  caught = false
  try:
    discard extractJsonObject("I refuse to answer.")
  except RaidError:
    caught = true
  check(caught, "and so is a reply with no object at all")
  done("only an unusable reply raises")

proc testFallbackAfterTwoFailures() =
  ## Two consecutive failures give the stalwart order plus a fallback event;
  ## a timeout on attempt 1 gives exactly one retry.
  var world = newWorld(testConfig())
  let seats = @[0, 1, 2, 3, 4]
  var decisions: seq[Decision]
  for seat in seats:
    decisions.add(Decision(order: scriptedOrder(world, seat, skStalwart),
      source: osFallback, attempts: 2, cause: fcParse,
      detail: "no JSON object in response"))
  world.applyTurn(seats, decisions)
  checkEq(world.eventsOf("fallback").len, Seats,
    "one fallback record per seat")
  let record = world.firstEvent("fallback")
  checkEq(record{"cause"}.getStr(), "parse_error", "with the cause")
  checkEq(record{"attempt"}.getInt(), 2, "and the attempt count")
  for slot in 0 ..< Seats:
    checkEq(world.cogs[slot].fbParse, 1, "counted per seat")
    checkEq(world.cogs[slot].fallbackTurns, 1, "and as a fallback turn")
    checkEq(validateOrder(world, slot, world.orders[slot]), "",
      "and the installed order is the legal stalwart one")
  done("two failures give the stalwart order plus a fallback event")

proc testDetailIsCapped() =
  var world = newWorld(testConfig())
  let seats = @[0]
  let decisions = @[Decision(order: scriptedOrder(world, 0, skStalwart),
    source: osFallback, attempts: 1, cause: fcTransport,
    detail: "e".repeat(900))]
  world.applyTurn(seats, decisions)
  let record = world.firstEvent("fallback")
  checkEq(record{"detail"}.getStr().runeLen, MaxDetailRunes,
    "recorded error text is capped at 200 runes")
  done("fallback detail is capped")

proc raisedBy(client: LlmClient, code: int, body: string): string =
  ## The message `llm.textOf` raises for a response, which is what becomes
  ## `fallback.detail`.
  try:
    discard client.textOf(Response(code: code, body: body), "",
      "https://example.invalid/v1/messages")
  except RaidError as error:
    return error.msg
  check(false, "textOf must raise on a " & $code & " response")

proc testCapturedErrorTextIsRuneSafe() =
  ## `llm.textOf` quotes an API error body - and a model reply cut off at
  ## max_tokens - into the `RaidError` whose message becomes
  ## `fallback.detail` in the replay. Every one of those cuts must land on a
  ## RUNE boundary, and a body that is not valid UTF-8 in the first place must
  ## not reach the replay either.
  let client = LlmClient()
  let emoji = "\u{1F525}"          ## FIRE, four bytes in UTF-8
  ## 401/403 quotes 400 characters, 429 and every other non-2xx quote 300, and
  ## the max_tokens branch quotes 160. Put the emoji astride each of those, so
  ## a byte cut would split it.
  for (code, cap) in [(403, 400), (429, 300), (500, 300)]:
    let body = "e".repeat(cap - 2) & emoji & "tail"
    let message = client.raisedBy(code, body)
    checkEq(validateUtf8(message), -1,
      "the " & $code & " message is valid UTF-8")
    check(emoji in message,
      "and carries the whole emoji, not two of its bytes (" & $code & ")")
    check("e".repeat(cap - 2) in message, "having quoted the body")
  let cutOff = $ %*{
    "stop_reason": "max_tokens",
    "content": [{"type": "text", "text": "e".repeat(158) & emoji & "tail"}]
  }
  let cutMessage = client.raisedBy(200, cutOff)
  checkEq(validateUtf8(cutMessage), -1,
    "a reply cut off at max_tokens is quoted on a rune boundary")
  check(emoji in cutMessage, "with its last rune whole")
  ## An error body that is itself invalid UTF-8 - a byte-truncated proxy page,
  ## or binary - is sanitised rather than passed through.
  let broken = "e".repeat(40) & emoji[0 ..< 2] & "tail"
  check(validateUtf8(broken) >= 0, "the fixture really is invalid UTF-8")
  checkEq(validateUtf8(client.raisedBy(429, broken)), -1,
    "an invalid-UTF-8 body is dropped, not quoted")
  done("captured error text is cut on rune boundaries")

proc testDetailAtTheCapIsValidUtf8() =
  ## The same string at the OTHER cap: `fallback.detail` is 200 runes, and the
  ## 200th rune of this message is the 4-byte emoji. It has to survive whole
  ## into the replay's event stream.
  let client = LlmClient()
  let emoji = "\u{1F525}"
  let prefix = "llm throttled (429): "
  let body = "e".repeat(MaxDetailRunes - prefix.runeLen - 1) & emoji & "tail"
  let message = client.raisedBy(429, body)
  check(message.startsWith(prefix), "the throttle message quotes the body")
  var world = newWorld(testConfig())
  world.applyTurn(@[0], @[Decision(order: scriptedOrder(world, 0, skStalwart),
    source: osFallback, attempts: 2, cause: fcTransport, detail: message)])
  let detail = world.firstEvent("fallback"){"detail"}.getStr()
  checkEq(detail.runeLen, MaxDetailRunes, "the detail is 200 runes")
  checkEq(detail, prefix & "e".repeat(MaxDetailRunes - prefix.runeLen - 1) &
    emoji, "cut on the rune, so the emoji is whole")
  checkEq(validateUtf8(detail), -1, "the recorded detail is valid UTF-8")
  let serialised = $ %*{"events": [world.firstEvent("fallback")]}
  checkEq(validateUtf8(serialised), -1,
    "and so are the replay bytes carrying it")
  discard parseJson(serialised)
  done("a fallback detail whose 200th rune is multi-byte stays valid UTF-8")

when isMainModule:
  testProsePrefixedJson()
  testFencedJson()
  testNestedObjectIsBalanced()
  testUnknownEnums()
  testWrongRoleIntent()
  testPointFormsAndClamping()
  testTargetForms()
  testDegradesToWaitWithNoTarget()
  testNoteAndSayCaps()
  testRuneBoundaryTruncation()
  testMissingIntentIsUnrecoverable()
  testFallbackAfterTwoFailures()
  testDetailIsCapped()
  testCapturedErrorTextIsRuneSafe()
  testDetailAtTheCapIsValidUtf8()
  echo "test_orders: parsing, repair and rune-boundary truncation check out"
