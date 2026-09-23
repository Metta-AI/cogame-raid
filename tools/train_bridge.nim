## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:raid-train-bridge tools/train_bridge.nim

import std/[json, os, strutils]
import raid/[arena, config, engine, llm, orders, scoring, sim, state, types,
             broadcast]

const
  OperatorPrompt = "Choose legal orders that maximize the team's score over the complete encounter."
  Variants = ["default", "sprint"]
  Intents = ["tank_boss", "taunt", "pick_up_adds", "kite", "heal_lowest",
    "heal_target", "shield_target", "conserve", "burn_boss", "kill_adds",
    "interrupt", "assist_target", "soak", "wait"]
  Stations = ["melee", "ranged", "spread", "edge", "point", "soak"]
  Reactions = ["dodge", "hold", "soak", "spread"]
  Roles = ["tank", "healer", "dps"]
  Telegraphs = ["cleave", "pour", "crucible"]
  Targets = ["", "boss", "Alpha", "Bravo", "Charlie", "Delta", "Echo"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc code(value: string, options: openArray[string]): int =
  for index, option in options:
    if value == option: return index
  raise newException(ValueError, "unknown observation category: " & value)

proc targetCode(value: string): int =
  for index, option in Targets:
    if value == option: return index
  doAssert value.len > 1 and value[0] == 'A'
  6 + parseInt(value[1 .. ^1])

proc targetChoice(value: string, view: JsonNode): int =
  if value in Targets: return targetCode(value)
  for index in 0 ..< view["adds"].len:
    if view["adds"][index]["id"].getStr() == value: return 7 + index
  raise newException(ValueError, "teacher targeted an unseen add: " & value)

proc choiceTarget(choice: int, view: JsonNode): string =
  if choice < Targets.len: return Targets[choice]
  let index = choice - Targets.len
  if index < view["adds"].len: view["adds"][index]["id"].getStr()
  else: ""

proc heads(): JsonNode =
  result = newJArray()
  for name in ["intent", "target", "station", "point_x", "point_y",
      "has_point", "on_telegraph"]:
    var options = newJArray()
    case name
    of "intent":
      for value in Intents: options.add(%value)
    of "target":
      for value in 0 .. 14: options.add(%value)
    of "station":
      for value in Stations: options.add(%value)
    of "point_x":
      for value in 0 .. 1235: options.add(%value)
    of "point_y":
      for value in 0 .. 659: options.add(%value)
    of "has_point": options = %*[false, true]
    of "on_telegraph":
      for value in Reactions: options.add(%value)
    else: raise newException(ValueError, "unknown action head")
    result.add(%*{"name": name, "choices": options})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation: " & $node)

proc addNumbers(values: var JsonNode, node: JsonNode) =
  for item in node: values.add(%item.number())

proc numeric(node: JsonNode, key: string): float =
  if node.hasKey(key): node[key].number() else: 0.0

proc values(view: JsonNode, variant: string, seat: int): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if variant == name: 1 else: 0))
  for index in 0 ..< Seats: result.add(%(if seat == index: 1 else: 0))
  for field in ["turn", "of", "tick", "phase"]:
    result.add(%view[field].number())
  for field in ["elapsed_s", "enrage_in_s", "hard_end_in_s"]:
    result.add(%view["clock"][field].number())
  let me = view["you"]
  result.add(%code(me["role"].getStr(), Roles))
  result.addNumbers(me["pos"])
  for field in ["hp", "max_hp", "shield", "threat"]:
    result.add(%me[field].number())
  result.add(%(if me["alive"].getBool(): 1 else: 0))
  result.add(%targetCode(me["attacking"].getStr()))
  for field in ["mana", "max_mana"]: result.add(%me.numeric(field))
  for field in ["taunt", "heal", "shield", "interrupt", "attack"]:
    result.add(%me["cooldowns_s"].numeric(field))
  result.add(%(if me.hasKey("casting"): 1 else: 0))
  result.add(%(if me.hasKey("casting"): targetCode(me["casting"]["target"].getStr())
    else: 0))
  result.add(%(if me.hasKey("casting"): me["casting"]["remaining_s"].number()
    else: 0.0))
  let boss = view["boss"]
  result.addNumbers(boss["pos"])
  for field in ["facing_brads", "hp", "max_hp", "hp_pct", "phase"]:
    result.add(%boss[field].number())
  result.add(%targetCode(boss["target"].getStr()))
  result.add(%(if boss["enraged"].getBool(): 1 else: 0))
  result.add(%(if boss["buffs"]["feed"].getBool(): 1 else: 0))
  result.add(%boss["buffs"]["spill_stacks"].number())
  for field in ["cleave", "pour", "overload", "adds"]:
    result.add(%boss["next_s"][field].number())
  result.add(%(if boss.hasKey("casting"): 1 else: 0))
  result.add(%(if boss.hasKey("casting"):
    boss["casting"]["remaining_s"].number() else: 0.0))
  doAssert view["raid"].len == Seats
  for actor in view["raid"]:
    result.add(%code(actor["role"].getStr(), Roles))
    result.addNumbers(actor["pos"])
    for field in ["hp", "max_hp", "shield", "threat"]:
      result.add(%actor[field].number())
    result.add(%(if actor["alive"].getBool(): 1 else: 0))
    result.add(%targetCode(actor["attacking"].getStr()))
    result.add(%code(actor["last_intent"].getStr(), Intents))
    result.add(%(if actor["say"].getStr().len > 0: 1 else: 0))
  let adds = view["adds"]
  doAssert adds.len <= 8
  result.add(%adds.len)
  for index in 0 ..< 8:
    if index < adds.len:
      let row = adds[index]
      result.add(%targetCode(row["id"].getStr()))
      result.addNumbers(row["pos"])
      for field in ["hp", "max_hp"]: result.add(%row[field].number())
      result.add(%targetCode(row["target"].getStr()))
    else:
      for _ in 0 ..< 6: result.add(%0)
  let pools = view["pools"]
  doAssert pools.len <= 6
  result.add(%pools.len)
  for index in 0 ..< 6:
    if index < pools.len:
      let row = pools[index]
      result.add(%row["id"].number())
      result.addNumbers(row["centre"])
      for field in ["radius", "expires_in_s"]:
        result.add(%row[field].number())
    else:
      for _ in 0 ..< 5: result.add(%0)
  let telegraphs = view["telegraphs"]
  doAssert telegraphs.len <= 8
  result.add(%telegraphs.len)
  for index in 0 ..< 8:
    if index < telegraphs.len:
      let row = telegraphs[index]
      result.add(%row["id"].number())
      result.add(%code(row["kind"].getStr(), Telegraphs))
      result.addNumbers(row["centre"])
      for field in ["resolves_in_s", "soak_needed", "facing_brads",
          "half_angle_brads", "reach", "radius"]:
        result.add(%row.numeric(field))
      result.add(%(if row["you_are_inside"].getBool(): 1 else: 0))
    else:
      for _ in 0 ..< 11: result.add(%0)
  for field in ["damage_to_boss", "healing_done"]:
    result.addNumbers(view["meters"][field])
  result.add(%view["callouts"].len)
  let last = view["your_last_order"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  if last.kind == JNull:
    for _ in 0 ..< 6: result.add(%0)
  else:
    result.add(%code(last["intent"].getStr(), Intents))
    result.add(%targetCode(last["target"].getStr()))
    result.add(%code(last["station"].getStr(), Stations))
    result.addNumbers(last["point"])
    result.add(%code(last["on_telegraph"].getStr(), Reactions))

proc action(order: Order, view: JsonNode): JsonNode =
  %*{"intent": $order.intent, "target": targetChoice(order.target, view),
    "station": $order.station, "point_x": order.px, "point_y": order.py,
    "has_point": order.hasPoint, "on_telegraph": $order.onTelegraph}

proc hostedOrder(candidate, view: JsonNode): JsonNode =
  result = %*{"intent": candidate["intent"],
    "target": choiceTarget(candidate["target"].getInt(), view),
    "station": candidate["station"], "on_telegraph": candidate["on_telegraph"]}
  if candidate["has_point"].getBool():
    result["point"] = %*[candidate["point_x"], candidate["point_y"]]

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "raid", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": OperatorPrompt & "\n\n" & $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: raid-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  let mapFile = parentDir(args[0]) / "data" / "foundry.mapspec.json"
  let map = arenaFromSpec(parseFile(mapFile))
  var game: Sim
  var active: seq[int]
  var views: array[Seats, JsonNode]
  var decisions: seq[Decision]
  var index = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var gameConfig = defaultGameConfig()
      let runtime = copy(variantConfig)
      runtime["tokens"] = %*["t0", "t1", "t2", "t3", "t4"]
      runtime["seed"] = %seedOf(request["seed"].getStr())
      gameConfig.update($runtime)
      game = initSim(gameConfig, map)
      game.encounterStart()
      active = livingSeats(game)
      for seat in active: views[seat] = seatView(game, seat)
      decisions = @[]
      index = 0
      id = 0
      response = views[active[index]].decision(active[index], id)
    of "encode":
      doAssert not game.done
      let seat = active[index]
      response = %*{"decision_id": id,
        "values": views[seat].values(variant, seat), "action_heads": heads()}
    of "teacher":
      doAssert not game.done
      response = %*{"response": $action(
        scriptedDecision(game, active[index], skStalwart).order,
        views[active[index]])}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let seat = active[index]
      decisions.add(Decision(order: parseOrder(candidate.hostedOrder(views[seat]),
        game.cogs[seat].role), source: osLlm))
      inc index
      inc id
      var observation: JsonNode
      if index < active.len:
        observation = views[active[index]].decision(active[index], id)
      else:
        game.applyTurn(active, decisions)
        while not game.done:
          game.stepOnce()
          if not game.done and game.turnBoundary():
            active = livingSeats(game)
            if active.len == 0:
              game.finish("complete", "wipe")
            break
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          var utilities = newJObject()
          for actor in 0 ..< Seats:
            scores[$actor] = outcome["scores"][actor]
            utilities[$actor] = %(2.0 * outcome["scores"][actor].number() /
              ScoreCeiling - 1.0)
          observation = %*{"kind": "terminal", "scores": scores,
            "utilities": utilities}
        else:
          for actor in active: views[actor] = seatView(game, actor)
          decisions = @[]
          index = 0
          observation = views[active[index]].decision(active[index], id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
