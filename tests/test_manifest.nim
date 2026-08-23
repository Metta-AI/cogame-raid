## The manifest template, cross-checked against the code that has to agree
## with it.

import std/[json, os, sets, strutils]
import support/helpers

proc manifest(): JsonNode =
  parseJson(repoFile("coworld_manifest_template.json"))

proc testSeatCountEverywhere() =
  let m = manifest()
  checkEq(m["variants"].len, 2, "two variants")
  for variant in m["variants"]:
    checkEq(variant["game_config"]["num_agents"].getInt(), Seats,
      "num_agents is 5 in variant " & variant["id"].getStr())
    checkEq(variant["game_config"]["players"].len, Seats,
      "and five players in variant " & variant["id"].getStr())
  let cert = m["certification"]
  checkEq(cert["game_config"]["num_agents"].getInt(), Seats,
    "num_agents is 5 in the certification fixture")
  checkEq(cert["players"].len, Seats, "five certification players")
  checkEq(cert["game_config"]["players"].len, Seats,
    "and five names in the fixture config")
  let ids = block:
    var known: HashSet[string]
    for entry in m["player"]:
      known.incl(entry["id"].getStr())
    known
  for seat in cert["players"]:
    check(seat["player_id"].getStr() in ids,
      "every certification seat names a declared player")
  done("num_agents is 5 in every variant and the certification fixture")

proc testResultsSchemaMatchesTheCode() =
  let m = manifest()
  let declared = m["game"]["results_schema"]["properties"]
  var schemaKeys: HashSet[string]
  for key, _ in declared.pairs:
    schemaKeys.incl(key)
  var emitted: HashSet[string]
  let world = runScripted(certConfig(), skStalwart)
  for key, _ in resultsJson(world).pairs:
    emitted.incl(key)
  checkEq(emitted, schemaKeys,
    "results_schema keys equal the keys the results builder emits")
  var required: HashSet[string]
  for key in m["game"]["results_schema"]["required"]:
    required.incl(key.getStr())
  checkEq(required, schemaKeys, "and every one of them is required")
  var listed: HashSet[string]
  for key in resultsKeys():
    listed.incl(key)
  checkEq(listed, schemaKeys, "and resultsKeys() lists exactly the same set")
  done("results_schema equals the results the code writes")

proc testEnumsAreClosed() =
  let m = manifest()
  let props = m["game"]["results_schema"]["properties"]
  var reasons: seq[string]
  for value in props["reason"]["enum"]:
    reasons.add(value.getStr())
  checkEq(reasons, @LegalReasons, "reason is the closed three-value enum")
  var rules: seq[string]
  for value in props["end_rule"]["enum"]:
    rules.add(value.getStr())
  checkEq(rules, @LegalEndRules, "end_rule is the closed five-plus-one enum")
  checkEq(props["scores"]["minItems"].getInt(), Seats, "scores minItems")
  checkEq(props["scores"]["maxItems"].getInt(), Seats, "scores maxItems")
  checkEq(props["scores"]["items"]["minimum"].getInt(), 0,
    "and scores are never negative")
  done("the results enums are closed")

proc testProtocolsAndDocs() =
  let m = manifest()
  let protocols = m["game"]["protocols"]
  for name in ["player", "global"]:
    check(protocols.hasKey(name), "game.protocols carries " & name)
    checkEq(protocols[name]["type"].getStr(), "text",
      name & " is text, not a URI")
    check(protocols[name]["value"].getStr().len > 400,
      name & " actually describes the protocol")
  let docs = m["game"]["docs"]
  checkEq(docs["readme"]["type"].getStr(), "text", "the readme is text")
  check(docs["readme"]["value"].getStr().len > 500, "and non-empty")
  checkEq(docs["pages"].len, 2, "two documentation pages")
  var pageIds: seq[string]
  for page in docs["pages"]:
    pageIds.add(page["id"].getStr())
    check(page.hasKey("title"), "each page has a title")
    checkEq(page["content"]["type"].getStr(), "text", "each page is text")
    check(page["content"]["value"].getStr().len > 500,
      page["id"].getStr() & " is non-empty")
  checkEq(pageIds, @["rules.md", "protocol.md"], "rules and protocol")
  done("both protocols and all three docs values are non-empty text")

proc testViewerAndTimeout() =
  let m = manifest()
  checkEq(m["game"]["replay_viewer"]["bundle"].getStr(),
    "static-replay-viewer", "the replay viewer is the STATIC bundle")
  checkEq(m["game"]["episode_timeout_minutes"].getInt(), 20,
    "episode_timeout_minutes is 20")
  let budget = 0.6 * 20.0 * 60.0
  for variant in m["variants"]:
    let wall = variant["game_config"]["wallClockBudgetSeconds"].getFloat()
    check(wall <= budget,
      variant["id"].getStr() & " plays inside 60 % of the platform timeout")
  check(m["certification"]["game_config"]["wallClockBudgetSeconds"]
    .getFloat() <= budget, "and so does the certification fixture")
  done("the static bundle, the 20-minute timeout and the 60 % budget")

proc testImageNamesAgreeWithCompose() =
  let m = manifest()
  checkEq(m["game"]["runnable"]["image"].getStr(), "{{GAME_IMAGE}}",
    "the game image is the template placeholder")
  for entry in m["player"]:
    checkEq(entry["image"].getStr(), "{{PLAYER_IMAGE}}",
      entry["id"].getStr() & " uses the player image placeholder")
    checkEq(entry["run"][0].getStr(), "/bin/raid-player",
      entry["id"].getStr() & " runs the player entrypoint")
  checkEq(m["game"]["runnable"]["run"][0].getStr(), "/bin/raid",
    "and the game runs /bin/raid")
  let compose = repoFile("compose.yaml")
  check("coworld-raid:latest" in compose,
    "compose.yaml names coworld-raid:latest")
  check("platform: linux/amd64" in compose, "on linux/amd64")
  check("network: host" in compose, "building with network: host")
  let smoke = repoFile("tools/ci/docker_smoke.sh")
  check("coworld-raid:ci" in smoke,
    "and the smoke defaults to the same image name")
  check("SMOKE_SEATS:-5" in smoke,
    "with the seat-count cross-check substituted to 5")
  done("the image names agree across compose, the manifest and the smoke")

proc testConfigSchemaCoversTheKnobs() =
  let m = manifest()
  let props = m["game"]["config_schema"]["properties"]
  for key in ["tokens", "players", "num_agents", "seed", "roles", "turnTicks",
      "enrageTicks", "maxTicks", "bossMaxHp", "turnBudgetSeconds",
      "wallClockBudgetSeconds", "episodeTimeoutSeconds",
      "playerConnectTimeoutSeconds", "mapPath", "model", "maxOutputTokens",
      "llmAttemptSeconds", "llmRetrySeconds", "showPlayerLabels",
      "gameOverTicks"]:
    check(props.hasKey(key), "config_schema declares " & key)
  checkEq(props["num_agents"]["minimum"].getInt(), Seats, "num_agents min")
  checkEq(props["num_agents"]["maximum"].getInt(), Seats, "num_agents max")
  checkEq(props["mapPath"]["default"].getStr(), "foundry", "the authored map")
  done("config_schema covers every knob the code reads")

proc testPoliciesFile() =
  let policies = parseJson(repoFile("tools/ci/policies.json"))
  checkEq(policies.len, 4, "four policies")
  var prompts = 0
  var scripted = 0
  var owned = 0
  for entry in policies:
    check(entry["name"].getStr().startsWith("raid-"), "named for this game")
    checkEq(entry["run"].getStr(), "/bin/raid-player", "one image, one binary")
    if entry["env"].hasKey("PLAYER_PROMPT"):
      prompts.inc
      check(entry["env"]["PLAYER_PROMPT"].getStr().len > 400,
        entry["name"].getStr() & " carries a real strategy prompt")
    if entry["env"].hasKey("PLAYER_SCRIPTED"):
      scripted.inc
      check(entry["env"]["PLAYER_SCRIPTED"].getStr() in
        ["stalwart", "greenhorn"], "a known baseline")
    if entry.hasKey("player"):
      owned.inc
      checkEq(entry["player"].getStr(),
        "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
        "champion #2 is owned by daveey-1")
  checkEq(prompts, 2, "two LLM prompt champions")
  checkEq(scripted, 2, "two scripted baselines")
  checkEq(owned, 1, "exactly one policy carries an owner")
  done("tools/ci/policies.json is two champions plus two baselines")

when isMainModule:
  testSeatCountEverywhere()
  testResultsSchemaMatchesTheCode()
  testEnumsAreClosed()
  testProtocolsAndDocs()
  testViewerAndTimeout()
  testImageNamesAgreeWithCompose()
  testConfigSchemaCoversTheKnobs()
  testPoliciesFile()
  echo "test_manifest: the manifest agrees with the code"
