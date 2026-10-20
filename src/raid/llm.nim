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
The boss is bolted to the centre and never moves. It swings at its threat-selected cog
every 1.5 s before enrage. It has three phases: Forge (100-70% hp), Slag (70-35%: adds and Overload),
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

const ReferenceRules = """Combat detail: threat retargeting happens once a second, outside a taunt lock,
and requires more than 10% extra threat to replace a living target. Enrage
shortens melee intervals to one second. Crawler pairs also spawn on entry to
phase three. Spill stacks cap at five. Listed damage amounts are base values;
feed (+25%), spill (+20% per stack), and enrage (x3) multiply boss damage,
including floor effects. Pillars do not block those effects.
All five seats receive the same score. A kill scores enrage time divided by
elapsed time, capped at 3.0. Every other ending scores the fraction of boss
health removed, regardless of when the encounter ended. Individual damage and
healing meters do not affect the score.
"""

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
      "5 seconds:", cadence & " seconds:") & ReferenceRules & ReplyRules
  let arena = "You are one of five cogs facing the scripted foundry boss SMELTER-9. The circular " &
    "pit has radius 300 pixels and centre (617,329), on a 1235x659 floor with x right and y down. " &
    "Four 40x40 pillars at (511,223), (723,223), (511,435), and (723,435) block movement, " &
    "sight, healing, and ranged attacks, but not floor effects."
  let roles = "Your tank, healer, or dps role is dealt each episode and appears in your view. " &
    "Use that role. The boss stays fixed at the centre and swings at the threat-selected cog every 1.5 seconds before enrage."
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
    of pvNumbered: """1. Assignment: control one of five cogs against the scripted foundry boss SMELTER-9. Your view
gives the tank, healer, or dps role dealt for this episode; fulfil that role.
2. Arena: a circular pit of radius 300 px is centred at (617,329) on a 1235x659 floor.
Coordinates increase rightward and downward. Four 40x40 pillars at (511,223), (723,223),
(511,435), (723,435) obstruct movement, sight, healing, and ranged attacks, but floor effects
cross them.
3. Boss: it stays at the centre and normally swings at the threat-selected cog every 1.5 s. Forge
covers 100–70% health; Slag, 70–35%, introduces adds and Overload; Meltdown, 35–0%, introduces
Crucible Pours. Damage triples at {enrage} s, and play stops at {deadline} s.
4. Floor attacks: CLEAVE gives 2 s warning for a 90-degree frontal cone reaching 180 px; only
the tank should stay inside. SLAG POUR puts a radius-90-px circle on a random non-tank, warns
2.5 s, then leaves fire for 10 s. Phase-three CRUCIBLE POUR has radius 110 px and a 3 s warning:
share its 240 damage among occupants, or leave it empty and give the boss a permanent +20%
damage stack.
5. Coordination: OVERLOAD takes 4 s and, if not interrupted by one dps, deals 70 to all five and
heals the boss 400. Two interrupts on one cast waste one. SLAG CRAWLERS spawn in pairs in phase
two; four living crawlers raise boss damage 25%.
6. Control: every {cadence} s, provide one order lasting the next {cadence} s. A deterministic
controller walks to your station, sustains attacks on your target, and immediately applies your
on_telegraph response when a warning starts. You cannot steer motors or react beyond that order:
specify the reaction instead of a manual dodge."""
    of pvQuestions: """Who am I? One of five cogs confronting SMELTER-9, a scripted foundry boss. The episode deals you
tank, healer, or dps; read your view and play that assignment.
Where is the fight? The floor is 1235x659 px with x pointing right and y down. Its playable pit
is a radius-300-px circle around (617,329). Pillars, each 40x40, stand at (511,223), (723,223),
(511,435), and (723,435). They stop travel and line of sight, including heals and ranged shots,
but not floor hazards.
How does it progress? The boss cannot leave the centre. Its usual swing targets the
threat-selected cog every 1.5 seconds. At 100–70% health it is in Forge; at 70–35%, Slag adds
crawlers and Overload; at 35–0%, Meltdown brings Crucible Pours. Enrage at {enrage} seconds
triples damage; {deadline} seconds ends the fight.
Which warnings matter? A CLEAVE paints a 90-degree cone 180 px ahead for 2 seconds: reserve it
for the tank. SLAG POUR chooses a random non-tank for a radius-90-px circle, with 2.5 seconds to
respond before a ten-second burning pool. In phase three, CRUCIBLE POUR warns for 3 seconds in a
radius-110-px circle. Its occupants split 240 damage. No occupant means another permanent +20%
boss-damage stack.
What needs teamwork? One dps must cancel the four-second OVERLOAD cast, which otherwise hits
each cog for 70 and restores 400 boss health. Duplicating an interrupt wastes one. Phase-two
SLAG CRAWLERS come two at a time; at least four alive grant the boss +25% damage.
When do I act? Choose your order every {cadence} seconds for the following {cadence} seconds.
Deterministic execution handles station movement, target attacks, and the immediate on_telegraph
reaction you approved. There is no direct motor control or faster response than that order
permits, so choose how to react rather than trying to dodge manually."""
    of pvReordered: """CONTROL — Submit one order per {cadence}-second interval. For the following {cadence} seconds a
deterministic controller takes you to your station, keeps attacking your target, and triggers
your chosen on_telegraph response as soon as a warning appears. Reactions must be authorised in
advance; you do not operate motors or dodge independently of the order.
COORDINATION — Stop OVERLOAD with one dps interrupt during its 4-second cast. Otherwise all five
cogs take 70 damage and SMELTER-9 recovers 400 health. Spending two interrupts on the same cast
wastes one. SLAG CRAWLERS arrive two per wave in phase two, and keeping four or more alive
increases boss damage by 25%.
HAZARDS — CLEAVE is a 180-px-long, 90-degree frontal cone announced 2 seconds ahead; only the
tank should occupy it. SLAG POUR warns a random non-tank for 2.5 seconds with a radius-90-px
circle and leaves a ten-second burning pool. Phase-three CRUCIBLE POUR announces a radius-110-px
circle for 3 seconds. Divide 240 damage among those inside; if nobody enters, the boss gains a
permanent +20% damage stack.
ENCOUNTER — Forge spans 100–70% boss health, Slag 70–35% with adds and Overload, and Meltdown
35–0% with Crucible Pours. Enrage triples damage after {enrage} seconds; the hard end is
{deadline} seconds. The stationary boss normally swings every 1.5 seconds at the highest-threat
cog.
PARTICIPANTS — You are one of five cogs fighting the scripted foundry boss SMELTER-9. Obey the
tank/healer/dps assignment dealt this episode and shown in your view.
LAYOUT — The circular pit has centre (617,329), radius 300 px, and sits on a 1235x659 floor, x
right and y down. Four square pillars of side 40 px occupy (511,223), (723,223), (511,435),
(723,435). They block movement, sight, heals, and ranged attacks while letting floor effects
through."""
    of pvHeldoutBriefing: """Enter the foundry as one member of a five-cog raid against SMELTER-9's fixed script. Look up
your dealt tank, healer, or dps role in the view, and perform its job.
Orient yourself in a circular pit, 300 px in radius, whose centre is (617,329). The containing
floor measures 1235x659; right is positive x and down is positive y. Four 40x40 pillars are
centred on (511,223), (723,223), (511,435), (723,435). Treat them as barriers to movement,
vision, heals, and ranged attacks; they provide no protection from floor effects.
Track the boss at the centre, where it remains anchored. Normally it swings on the
threat-selected cog at 1.5-second intervals. Its health drives Forge from 100 to 70%, Slag from
70 to 35% with adds and Overload, and Meltdown below 35% with Crucible Pours. At {enrage}
seconds its damage becomes triple; the encounter cannot continue past {deadline} seconds.
Prepare for CLEAVE: two seconds of warning precede a 90-degree cone extending 180 px forward,
which only the tank should occupy. A random non-tank receives SLAG POUR, a radius-90-px warning
circle lasting 2.5 seconds followed by ten seconds of burning ground. During phase three,
CRUCIBLE POUR instead gives three seconds in a radius-110-px circle. Occupants divide its 240
damage; abandoning it permanently adds 20% boss damage.
Arrange a single dps interrupt for each four-second OVERLOAD. Letting it finish costs each cog
70 health and gives the boss 400 health; double-interrupting spends one needlessly. Phase-two
SLAG CRAWLERS appear in pairs, with four or more survivors boosting boss damage by 25%.
Program your response before trouble arrives. Once per {cadence} seconds, issue an order for the
next {cadence} seconds. The deterministic executor moves to your station, maintains target
attacks, and activates your on_telegraph choice immediately on a warning. It does not offer
direct motor access or reactions faster than the order allows: choose a response rather than a
manual dodge."""
    of pvHeldoutReference: """Order interface: one instruction controls your cog for {cadence} seconds and is replaced every
{cadence} seconds. Deterministic execution supplies travel to the station, continued attacks
against the target, and the authorised on_telegraph behaviour at warning onset. Motor inputs are
not yours to set. Reaction speed is bounded by your instruction, so preselect the response
instead of attempting a dodge yourself.
Roster: five cogs oppose the scripted foundry boss SMELTER-9. The current episode deals a tank,
healer, or dps assignment to you; your view identifies it, and your play must follow it.
Coordinates: on the 1235x659 floor, x grows right and y grows down. A radius-300-px pit
surrounds (617,329). Pillar centres are (511,223), (723,223), (511,435), and (723,435), each
with a 40x40 footprint. These obstacles interrupt travel, sight, healing, and ranged attacks,
not floor effects.
Boss schedule: the boss stays central, normally swinging at the threat-selected cog every 1.5 s.
Forge occupies the 100–70% health band; Slag occupies 70–35% and enables adds plus Overload;
Meltdown occupies 35–0% and enables Crucible Pours. Damage is tripled from {enrage} s. The fight
ends by {deadline} s.
Warning geometry: CLEAVE has a 2 s lead, 90-degree frontal arc, and 180 px reach; keep everyone
but the tank out. SLAG POUR has a 2.5 s lead and radius 90 px, selects a random non-tank, and
leaves a 10 s burning pool. Phase-three CRUCIBLE POUR has a 3 s lead and radius 110 px. Those
within share 240 damage; an empty circle awards a permanent +20% damage stack to the boss.
Group obligations: OVERLOAD's 4 s cast requires one dps interrupt to prevent 70 damage per cog
and 400 healing to the boss. A second interrupt on the same cast is wasted. SLAG CRAWLERS spawn
as pairs during phase two; an alive count of four or more confers +25% boss damage."""
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  briefing.replace("{enrage}", enrage).replace("{deadline}", deadline).replace(
    "{cadence}", cadence) & "\n\n" & ReferenceRules & ReplyRules

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
