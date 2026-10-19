## Prompt inference in an ordinary Raid player.
##
## Hosted policy containers receive a Messages API sidecar. Local policy runs
## may use ANTHROPIC_API_KEY directly. The game never receives either secret.

import std/[json, os, strutils, unicode]
import curly
import types, labels, prompts, config

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

  CanonicalIntroduction = "You are one of five cogs fighting SMELTER-9, a scripted foundry boss, in a round pit\n"
  CommonRules = """
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
"""

  RetryHint* = "\nYour previous reply was invalid, reply with a single JSON " &
    "object beginning with '{' carrying at least an \"intent\" legal for " &
    "your role."

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
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

proc systemPrompt*(selection: PromptSelection, config: GameConfig): string =
  var enrage = formatFloat(float(config.enrageTicks) / float(TargetFps), ffDecimal, 2)
  var deadline = formatFloat(float(config.maxTicks) / float(TargetFps), ffDecimal, 2)
  var cadence = formatFloat(float(config.turnTicks) / float(TargetFps), ffDecimal, 2)
  enrage.trimZeros()
  deadline.trimZeros()
  cadence.trimZeros()
  if selection.selectedVariant == pvCanonical:
    return CanonicalIntroduction & CommonRules.replace("At 240 s", "At " & enrage & " s").replace(
      "at 270 s.", "at " & deadline & " s.").replace("Every 5 seconds", "Every " & cadence & " seconds").replace(
      "5 seconds:", cadence & " seconds:") & ReplyRules
  let arena = "You are one of five cogs facing the scripted foundry boss SMELTER-9. The circular " &
    "pit has radius 300 pixels and centre (617,329), on a 1235x659 floor with x right and y down. " &
    "Four 40x40 pillars at (511,223), (723,223), (511,435), and (723,435) block movement, " &
    "sight, healing, and ranged attacks, but not floor effects."
  let roles = "Your tank, healer, or dps role is dealt each episode and appears in your view. " &
    "Use that role. The boss stays fixed at the centre and swings at the highest-threat cog every 1.5 seconds."
  let phases = "The phases are Forge at 100-70% health, Slag at 70-35% with adds and Overload, " &
    "and Meltdown at 35-0% with Crucible Pours. At " & enrage & " seconds, enrage triples " &
    "boss damage. The fight stops at " & deadline & " seconds."
  let hazards = "CLEAVE warns for two seconds before hitting a 90-degree cone extending 180 pixels " &
    "in front of the boss; only the tank should occupy it. SLAG POUR targets a random non-tank " &
    "with a 90-pixel circle, warns for 2.5 seconds, and leaves a burning pool for ten seconds. " &
    "Phase-three CRUCIBLE POUR warns for three seconds over a 110-pixel circle. Its 240 damage " &
    "is shared among everyone inside. If nobody soaks it, the boss permanently gains a +20% damage stack."
  let teamwork = "OVERLOAD casts for four seconds. Unless one dps interrupts, it hits each of " &
    "the five cogs for 70 and heals the boss for 400. Two interrupts on one cast waste an " &
    "interrupt. SLAG CRAWLERS arrive in pairs during phase two; four or more living adds " &
    "increase boss damage by 25%."
  let control = "Issue one order every " & cadence & " seconds. The deterministic controller " &
    "executes it for the next " & cadence & " seconds, moving to your station, maintaining " &
    "attacks on your target, and immediately applying the on_telegraph reaction you chose " &
    "when a warning appears. You do not drive motors or react faster than the order permits: " &
    "choose the reaction rather than attempting a manual dodge."
  let briefing = case selection.selectedVariant
    of pvPlain: arena & "\n\n" & roles & "\n\n" & phases & "\n\n" & hazards & "\n\n" & teamwork & "\n\n" & control
    of pvNumbered: "1. Arena\n" & arena & "\n2. Role\n" & roles & "\n3. Phases\n" & phases & "\n4. Floor mechanics\n" & hazards & "\n5. Coordination\n" & teamwork & "\n6. Orders\n" & control
    of pvQuestions: "Who am I?\n" & roles & "\nWhere do we fight?\n" & arena & "\nHow does the fight progress?\n" & phases & "\nWhat must we handle?\n" & hazards & "\n" & teamwork & "\nHow do I react?\n" & control
    of pvReordered: "ORDER CONTROL\n" & control & "\nMECHANICS\n" & hazards & "\n" & teamwork & "\nPHASE CLOCK\n" & phases & "\nROLE\n" & roles & "\nARENA\n" & arena
    of pvHeldoutBriefing: "Read your assignment.\n" & roles & "\nLocate the encounter.\n" & arena & "\nTrack the phases.\n" & phases & "\nPrepare coordinated responses.\n" & teamwork & "\n" & hazards & "\nSet your order.\n" & control
    of pvHeldoutReference: "Arena reference: " & arena & "\nControl reference: " & control & "\nPhase reference: " & phases & "\nRole reference: " & roles & "\nMechanics reference: " & teamwork & "\n" & hazards
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  briefing & "\n\n" & ReplyRules

type
  LlmTransport = enum
    ltNone, ltSidecar, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool

  LlmError* = object of RaidError

proc resolveApiKey(): string =
  getEnv("ANTHROPIC_API_KEY").strip()

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    model: "claude-haiku-4-5-20251001",
    maxOutputTokens: 900
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    echo "raid llm: sidecar transport, model ", result.model
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

proc userPrompt*(view: JsonNode, prompt: string): string =
  ## The operator prompt never crosses the game socket or enters the replay.
  result = runeCap(prompt.strip(), MaxPromptRunes)
  if result.len > 0:
    result.add("\n\n")
  result.add($view)

proc requestFor*(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  body["model"] = %client.model
  if client.transport == ltSidecar:
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string):
    string =
  ## Raises `RaidError` with a one-line description of anything that is not a
  ## usable reply. That message becomes `fallback.detail` in the replay, so
  ## every captured fragment of a body is cut with `runeCap` - on RUNE
  ## boundaries, never bytes (`labels.nim:31`).
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = runeCap(response.body, 400)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = runeCap(response.body, 300)
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      runeCap(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & runeCap(result, 160))
