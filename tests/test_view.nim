## The observation contract: what a seat sees, and — more importantly — what
## it does not.

import std/[json, strutils]
import support/helpers
import raid/[broadcast]

proc buildWorld(): Sim =
  result = newWorld(testConfig())
  result.names = @["daveey", "daveey-1", "Baseline (1)", "Baseline (2)",
    "Baseline (1)"]
  result.policyKinds = @["llm", "llm", "scripted", "scripted", "scripted"]
  result.boss.phase = 2
  result.tick = 2040
  result.turn = 17
  result.adds.add(Add(id: 5, x: 700, y: 250, hp: 140, alive: true, target: 0))
  result.pools.add(Pool(id: 12, cx: 560, cy: 470, radius: PourRadius,
    spawnTick: 1900, alive: true))
  result.telegraphs.add(Telegraph(id: 41, kind: tkPour, cx: 520, cy: 430,
    radius: PourRadius, fuse: 34, soakNeeded: 0, drawnOn: 2))
  for slot in 0 ..< Seats:
    result.orders[slot] = Order(
      intent: defaultIntentFor(result.cogs[slot].role),
      station: stRanged, onTelegraph: rxDodge,
      note: "PRIVATE-NOTE-SLOT-" & $slot,
      say: "callout-" & $slot)
    result.says[slot] = "callout-" & $slot
    result.haveOrder[slot] = true

proc testEveryDocumentedFieldIsPresent() =
  let world = buildWorld()
  let view = seatView(world, 2)
  for key in ["turn", "of", "tick", "phase", "phase_name", "clock", "you",
      "boss", "telegraphs", "raid", "adds", "pools", "callouts", "meters",
      "your_last_order"]:
    check(view.hasKey(key), "the view carries " & key)
  for key in ["elapsed_s", "enrage_in_s", "hard_end_in_s"]:
    check(view["clock"].hasKey(key), "clock." & key)
  for key in ["alias", "role", "pos", "alive", "hp", "max_hp", "shield",
      "threat", "attacking", "cooldowns_s"]:
    check(view["you"].hasKey(key), "you." & key)
  for key in ["name", "pos", "facing_brads", "hp", "max_hp", "hp_pct",
      "phase", "target", "enraged", "buffs", "next_s"]:
    check(view["boss"].hasKey(key), "boss." & key)
  for key in ["cleave", "pour", "overload", "adds"]:
    check(view["boss"]["next_s"].hasKey(key), "boss.next_s." & key)
  checkEq(view["raid"].len, Seats, "all five cogs are visible")
  checkEq(view["adds"].len, 1, "the live add is visible")
  checkEq(view["pools"].len, 1, "the pool is visible")
  checkEq(view["telegraphs"].len, 1, "the telegraph is visible")
  check(view["telegraphs"][0].hasKey("you_are_inside"),
    "with whether this seat is standing in it")
  done("every documented view field is present")

proc testNothingHiddenLeaks() =
  let world = buildWorld()
  for slot in 0 ..< Seats:
    let text = $seatView(world, slot)
    ## The seed.
    check($world.config.seed notin text or world.config.seed == 0,
      "the seed never appears in a seat's view")
    ## Other seats' private notes.
    for other in 0 ..< Seats:
      if other == slot:
        continue
      check("PRIVATE-NOTE-SLOT-" & $other notin text,
        "seat " & $slot & " cannot read seat " & $other & "'s note")
    ## Its own note is not echoed back except inside your_last_order, which is
    ## its own order; the grep below is for OTHER seats only.
    ## Real player names.
    for name in ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]:
      check(name notin text,
        "no real player name reaches seat " & $slot & "'s view")
    ## Prompt text.
    check("PLAYER_PROMPT" notin text, "no prompt text")
  done("the seed, other seats' notes, prompts and real names never leak")

proc testCalloutsArePreviousTurnSays() =
  let world = buildWorld()
  let view = seatView(world, 0)
  checkEq(view["callouts"].len, Seats - 1,
    "four callouts: everyone but yourself")
  var seen: seq[string]
  for record in view["callouts"]:
    seen.add(record["alias"].getStr() & "=" & record["say"].getStr())
  checkEq(seen, @["Bravo=callout-1", "Charlie=callout-2", "Delta=callout-3",
    "Echo=callout-4"], "carrying exactly the previous turn's say strings")
  done("callouts are the previous turn's say strings")

proc testDeadSeatView() =
  var world = buildWorld()
  world.cogs[3].alive = false
  world.cogs[3].hp = 0
  let view = seatView(world, 3)
  checkEq(view["you"]["alive"].getBool(), false,
    "a dead seat's view says so")
  checkEq(view["raid"][3]["alive"].getBool(), false,
    "and the raid list agrees")
  done("a dead seat's view has you.alive == false")

proc testRoleSpecificBlocks() =
  let world = buildWorld()
  let healer = world.healerSlot()
  let healerView = seatView(world, healer)
  check(healerView["you"].hasKey("mana"), "the healer sees its mana")
  check(healerView["you"].hasKey("max_mana"), "and its pool size")
  check(healerView["you"]["cooldowns_s"].hasKey("shield"),
    "and its shield cooldown")
  let tank = world.tankSlot()
  let tankView = seatView(world, tank)
  check(not tankView["you"].hasKey("mana"), "a tank has no mana block")
  check(tankView["you"]["cooldowns_s"].hasKey("taunt"),
    "but it does have a taunt cooldown")
  var dps = -1
  for slot in 0 ..< Seats:
    if world.cogs[slot].role == roleDps:
      dps = slot
      break
  let dpsView = seatView(world, dps)
  check(not dpsView["you"].hasKey("mana"), "a dps has no mana block")
  check(dpsView["you"]["cooldowns_s"].hasKey("interrupt"),
    "but it does have an interrupt cooldown")
  done("role-specific blocks appear only for the role that owns them")

proc testGlobalSnapshotDoesCarryRealNames() =
  ## The other half of the two-name-space pin: the SPECTATOR stream must map
  ## aliases back to real policy names.
  let world = buildWorld()
  let text = $globalSnapshot(world, @[true, true, false, false, false])
  check("daveey" in text, "the spectator stream carries real policy names")
  check("Alpha" in text, "alongside the aliases")
  check("PRIVATE-NOTE-SLOT-0" in text,
    "and the notes, which are spectator-side material")
  done("real names live spectator-side, and only there")

when isMainModule:
  testEveryDocumentedFieldIsPresent()
  testNothingHiddenLeaks()
  testCalloutsArePreviousTurnSays()
  testDeadSeatView()
  testRoleSpecificBlocks()
  testGlobalSnapshotDoesCarryRealNames()
  echo "test_view: the observation contract holds"
