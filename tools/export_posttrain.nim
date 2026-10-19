## Export complete private candidates; shared review owns training admission.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import raid/[arena, baselines, broadcast, config, engine, llm, orders,
  scoring, state, types, prompts, evidence]

const OperatorPrompt = "Choose legal orders that maximize the team's score over the complete encounter."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  let map = loadArena("foundry")
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config.promptSelection = selection
    var sim = initSim(config, map)
    let family = "raid-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var rows = newJArray()
    var latest: array[Seats, int]
    for seat in 0 ..< Seats: latest[seat] = -1
    var pending: seq[int]
    let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
      pending = seats
      for seat in seats:
        let teacher = Decision(order: scriptedOrder(view, seat, skStalwart),
          source: osScripted)
        var completion = orderToJson(teacher.order)
        if not teacher.order.hasPoint:
          completion.delete("point")
        let parsed = parseOrder(completion, view.cogs[seat].role)
        doAssert repairOrder(view, seat, parsed) ==
          repairOrder(view, seat, teacher.order)
        let system = systemPrompt(selection)
        let observation = seatView(view, seat)
        let user = userPrompt(observation, OperatorPrompt)
        observation["prompt_template"] = promptMetadata(selection, system, user)
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        let attemptId = $rows.len & "-teacher"
        latest[seat] = rows.len
        rows.add(%*{
          "schema_version": "1", "event_type": "decision", "episode_id": episode,
          "decision_id": $rows.len, "decision_index": rows.len,
          "game": "raid", "game_version": "source-" & sourceRevision,
          "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
          "observation": observation, "prompt": messages,
          "attempts": [{"attempt_id": attemptId, "policy": "scripted-stalwart",
            "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
            "response": $completion, "parsed_action": orderToJson(repairOrder(view, seat, parsed)),
            "accepted": true, "request": newJNull(), "platform_call_id": newJNull(),
            "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": newJNull(),
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
        result.add(Decision(order: parsed, source: osScripted))
    let clock: Clock = proc (): float = 0.0
    let onTurn: TurnHook = proc (view: Sim) =
      for seat in pending:
        let record = rows[latest[seat]]
        let executed = orderToJson(view.orders[seat])
        doAssert executed == record["attempts"][0]["parsed_action"]
        record["executed_action"] = executed
    sim.runEncounter(decide, clock, onTurn = onTurn)
    doAssert sim.done and rows.len > 0 and sim.reason == "complete"
    let outcome = sim.resultsJson()
    for seat in 0 ..< Seats:
      doAssert latest[seat] >= 0
      rows[latest[seat]]["terminal"] = %true
    for row in rows: stream.writeLine($row)
    var participants = newJObject()
    for seat in 0 ..< Seats: participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "raid", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": participants}))
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "end_rule": sim.endRule})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "raid",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-stalwart",
    "operator_prompt": OperatorPrompt,
    "prompt_configuration": selectionMetadata(selection),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", games
