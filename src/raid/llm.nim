## Claude-backed decision making, one parallel batch per turn.
##
## Raid is a simultaneous-decision game: at each decision turn every LIVING
## seat's request goes out together in ONE `curly.makeRequests` batch, exactly
## bullwhip's `decideAll` (`src/bullwhip/llm.nim:419-472`). Seats are never
## queried sequentially - that is what blows the play budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With none of them the client disables itself on the first discovery, every
## turn falls back instantly with no network wait, and offline certification
## still completes. That fallback is load-bearing.

import std/[json, os, strutils, unicode]
import bitworld/runtime
import curly
import types, config, state, sim, orders, baselines, broadcast, labels

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

  SystemPrompt* = """
You are one of five cogs fighting SMELTER-9, a scripted foundry boss, in a round pit
300 pixels in radius centred at (617,329) on a 1235x659 floor, x right, y down. Four
40x40 pillars at (511,223) (723,223) (511,435) (723,435) block movement, sight, heals
and ranged attacks - but not floor effects.
Your role was DEALT to you this episode: tank, healer or dps. It is in your view. Play
the role you got.
The boss is bolted to the centre and never moves. It swings at its highest-threat cog
every 1.5 s. It has three phases: Forge (100-70% hp), Slag (70-35%: adds and Overload),
Meltdown (35-0%: Crucible Pours). At 240 s it ENRAGES (triple damage) and the fight is
hard-stopped at 270 s.
Mechanics: CLEAVE is a 90-degree cone 180 px in front of the boss, telegraphed for 2 s -
only the tank should be in it. SLAG POUR drops a 90 px circle on a random non-tank,
telegraphed 2.5 s, and leaves a burning pool for 10 s. CRUCIBLE POUR (phase 3) is a
110 px circle telegraphed 3 s: 240 damage SPLIT between everyone standing in it, and if
NOBODY stands in it the boss gains a permanent +20% damage stack. OVERLOAD is a 4 s cast
that hits all five for 70 and heals the boss 400 unless ONE dps interrupts it - two
interrupts on the same cast wastes one. SLAG CRAWLERS spawn in pairs during phase 2; at
four or more alive the boss deals +25% damage.
Every 5 seconds you issue ONE order. A deterministic controller executes it for the next
5 seconds: it walks you to your station, holds your attack on your target, and performs
the reaction you pre-authorised in "on_telegraph" the instant a telegraph appears. You
do not drive motors directly, and you cannot react faster than your order allows - so
choose the reaction, not the dodge.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"intent":"<one of the legal intents for your role>",
 "target":"boss|A1..A8|Alpha|Bravo|Charlie|Delta|Echo|null",
 "station":"melee|ranged|spread|edge|point|soak",
 "point":[x,y],              // used when station is "point"; clamped into the pit
 "on_telegraph":"dodge|hold|soak|spread",
 "note":"<=160 chars",       // your reasoning, shown to spectators only
 "say":"<=32 chars"}         // one short callout; your four team-mates SEE this next turn
Tank intents: tank_boss, taunt, pick_up_adds, kite, soak, wait.
Healer intents: heal_lowest, heal_target, shield_target, conserve, soak, wait.
Dps intents: burn_boss, kill_adds, interrupt, assist_target, soak, wait.
Stations: melee = 40 px ring around your target; ranged = 260 px ring from the boss;
spread = at least 140 px from every team-mate; edge = the pit rim behind you;
point = the exact point you named; soak = the middle of the live pour circle.
on_telegraph: dodge = leave the shape; hold = stay and keep attacking; soak = step into
a pour circle; spread = get 140 px from everyone. The tank normally holds cleaves and
everyone else dodges them.
"""

  RetryHint = "\nYour previous reply was invalid, reply with a single JSON " &
    "object beginning with '{' carrying at least an \"intent\" legal for " &
    "your role."

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    attemptSeconds*: int
    retrySeconds*: int
    disabled*: bool

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "raid llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "raid llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc ceilSeconds(value: float): int =
  result = int(value)
  if value > result.float:
    result.inc
  if result < 1:
    result = 1

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    attemptSeconds: ceilSeconds(config.llmAttemptSeconds),
    retrySeconds: ceilSeconds(config.llmRetrySeconds)
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "raid llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "raid llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "raid llm: no LLM credentials; using scripted fallback"

proc userPrompt*(sim: Sim, slot: int, prompt: string): string =
  ## The seat's operator prompt, a blank line, then the seat's view JSON. The
  ## prompt text itself is never echoed into the replay or the results.
  result = prompt.strip()
  if result.len > 0:
    result.add("\n\n")
  result.add($seatView(sim, slot))

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(RaidError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(RaidError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(RaidError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(RaidError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(RaidError, "anthropic error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(RaidError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(RaidError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc causeOf(message: string): FallbackCause =
  let lowered = message.toLowerAscii()
  if "transport" in lowered or "timeout" in lowered or
      "timed out" in lowered or "connect" in lowered:
    fcTimeout
  elif "auth" in lowered or "credential" in lowered:
    fcNoCreds
  elif "error" in lowered and "json" notin lowered:
    fcTransport
  else:
    fcParse

proc scriptedDecision*(sim: Sim, slot: int, kind: ScriptKind): Decision =
  Decision(
    order: scriptedOrder(sim, slot, (if kind == skNone: skStalwart else: kind)),
    source: osScripted, latencyMs: 0, attempts: 0, cause: fcNone
  )

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order. Never raises: any failure
  ## falls back to the stalwart order so the encounter always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone:
      result[index] = scriptedDecision(sim, seat, kind)
    elif client == nil or client.disabled:
      result[index] = scriptedDecision(sim, seat, skStalwart)
      result[index].source = osFallback
      result[index].cause = fcNoCreds
      result[index].detail = runeCap("no LLM credentials", MaxDetailRunes)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = userPrompt(sim, seat, prompts[seat])
      if attempt > 0:
        user.add(RetryHint)
      let request = client.requestFor(SystemPrompt, user)
      batch.post(request.url, request.headers, request.body, $index)
    ## ONE parallel batch for every open seat. Never a loop of single calls.
    let timeout =
      if attempt == 0: client.attemptSeconds else: client.retrySeconds
    let responses = client.curl.makeRequests(batch, timeout)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let raw = parseOrder(extractJsonObject(text), sim.cogs[seat].role)
        result[index] = Decision(
          order: repairOrder(sim, seat, raw), source: osLlm,
          attempts: attempt + 1, cause: fcNone
        )
      except CatchableError as error:
        echo "raid llm: seat ", seat, " attempt ", attempt + 1, " failed: ",
          error.msg
        result[index] = Decision(
          order: scriptedOrder(sim, seat, skStalwart), source: osFallback,
          attempts: attempt + 1, cause: causeOf(error.msg),
          detail: runeCap(error.msg, MaxDetailRunes)
        )
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "raid llm: seat ", seat, " falling back to the scripted order"
    if result[index].source != osFallback:
      result[index] = scriptedDecision(sim, seat, skStalwart)
      result[index].source = osFallback
      result[index].cause = fcTimeout
