## Export complete Raid encounters as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]

import std/[json, os, osproc, strutils]
import raid/[arena, baselines, broadcast, config, engine, llm, orders,
  scoring, state, types, prompts]

const OperatorPrompt = "Choose legal orders that maximize the team's score over the complete encounter."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let configured = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert configured.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference}, "held-out wording is evaluation only"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  let map = loadArena("foundry")
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + games:
    var selection = configured
    let split = ord(seed mod 5 == 0)
    if selection.variant == pvMixed:
      selection.seed += wordingCounts[split]
      inc wordingCounts[split]
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config.promptSelection = selection
    var sim = initSim(config, map)
    var rows: seq[string]
    let decide: Decider = proc (view: Sim, seats: seq[int]): seq[Decision] =
      for seat in seats:
        let teacher = Decision(order: scriptedOrder(view, seat, skStalwart),
          source: osScripted)
        var completion = orderToJson(teacher.order)
        if not teacher.order.hasPoint:
          completion.delete("point")
        let parsed = parseOrder(completion, view.cogs[seat].role)
        doAssert repairOrder(view, seat, parsed) ==
          repairOrder(view, seat, teacher.order)
        rows.add($(%*{
          "episode_id": "raid-" & variant & "-" & $seed & "-" &
            $selection.variant & "-" & $selection.selectedVariant & "-" & $selection.seed,
          "seed": "raid-" & $seed,
          "decision_id": rows.len,
          "prompt_template": selection.promptMetadata(systemPrompt(selection, config), userPrompt(seatView(view, seat), OperatorPrompt)),
          "prompt": [
            {"role": "system", "content": systemPrompt(selection, config)},
            {"role": "user", "content": userPrompt(seatView(view, seat),
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "raid",
          "action_schema_revision": "raid-order-v1"
        }))
        result.add(Decision(order: parsed, source: osScripted))
    let clock: Clock = proc (): float = 0.0
    sim.runEncounter(decide, clock)
    doAssert sim.done and rows.len > 0 and sim.reason == "complete"
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "end_rule": sim.endRule})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "raid",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-stalwart",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
