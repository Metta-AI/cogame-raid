## GameConfig lifecycle: defaults, the runtime JSON overlay, and the fully
## resolved config document that is pinned verbatim into every replay.

import std/[json, strutils]
import types

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    roles*: seq[string]              ## empty = deal from the seed
    turnTicks*: int
    enrageTicks*: int
    maxTicks*: int
    bossMaxHp*: int
    turnBudgetSeconds*: float
    wallClockBudgetSeconds*: float
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: float
    mapPath*: string
    model*: string
    maxOutputTokens*: int
    llmAttemptSeconds*: float
    llmRetrySeconds*: float
    showPlayerLabels*: bool
    gameOverTicks*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: Seats,
    turnTicks: 120,
    enrageTicks: 5760,
    maxTicks: 6480,
    bossMaxHp: 26000,
    turnBudgetSeconds: 10.0,
    wallClockBudgetSeconds: 660.0,
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 90.0,
    mapPath: "foundry",
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmAttemptSeconds: 6.5,
    llmRetrySeconds: 3.0,
    showPlayerLabels: true,
    gameOverTicks: 96
  )

proc deadlineSeconds*(value: float): int =
  ## The integer deadline an LLM attempt actually gets. curl's OPT_TIMEOUT -
  ## and therefore `curly.makeRequests` - is whole seconds, so a 6.5 s
  ## configured deadline is really 7 s of waiting. Rounding UP is deliberate:
  ## a deadline shorter than the configured one would cut a reply that was
  ## still inside its budget. Every check against the turn budget has to use
  ## this number rather than the configured float.
  result = int(value)
  if value > result.float:
    result.inc
  if result < 1:
    result = 1

proc validate*(config: GameConfig) =
  if config.numAgents != Seats:
    raise newException(RaidError,
      "num_agents must be " & $Seats & ", got " & $config.numAgents)
  if config.turnTicks < 1:
    raise newException(RaidError, "turnTicks must be positive")
  if config.enrageTicks < 1 or config.maxTicks < config.enrageTicks:
    raise newException(RaidError,
      "maxTicks must be at least enrageTicks and both positive")
  if config.bossMaxHp < 1:
    raise newException(RaidError, "bossMaxHp must be positive")
  if config.roles.len notin [0, Seats]:
    raise newException(RaidError,
      "roles must name exactly " & $Seats & " roles when present")
  for role in config.roles:
    discard parseRole(role)
  ## Both attempt deadlines must fit inside one turn budget, or the outer
  ## per-turn deadline can never be honoured - checked on the EFFECTIVE
  ## whole-second deadlines, because those are what the turn really spends.
  ## At the shipped 6.5 + 3.0 that is 7 + 3 = exactly the 10.0 s budget: the
  ## turn budget is honoured, with no slack left over.
  let attempt = deadlineSeconds(config.llmAttemptSeconds)
  let retry = deadlineSeconds(config.llmRetrySeconds)
  if (attempt + retry).float > config.turnBudgetSeconds + 1e-9:
    raise newException(RaidError,
      "llmAttemptSeconds + llmRetrySeconds must be <= turnBudgetSeconds " &
      "once rounded up to whole seconds (" & $attempt & " + " & $retry &
      " > " & $config.turnBudgetSeconds & ")")
  if config.wallClockBudgetSeconds >
      0.6 * config.episodeTimeoutSeconds.float + 1e-9:
    raise newException(RaidError,
      "wallClockBudgetSeconds must be inside 60% of episodeTimeoutSeconds")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(RaidError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("num_agents"):
    config.numAgents = node["num_agents"].getInt()
  if node.hasKey("roles"):
    config.roles = @[]
    for role in node["roles"]:
      config.roles.add(role.getStr())
  if node.hasKey("turnTicks"):
    config.turnTicks = node["turnTicks"].getInt()
  if node.hasKey("enrageTicks"):
    config.enrageTicks = node["enrageTicks"].getInt()
  if node.hasKey("maxTicks"):
    config.maxTicks = node["maxTicks"].getInt()
  if node.hasKey("bossMaxHp"):
    config.bossMaxHp = node["bossMaxHp"].getInt()
  if node.hasKey("turnBudgetSeconds"):
    config.turnBudgetSeconds = node["turnBudgetSeconds"].getFloat()
  if node.hasKey("wallClockBudgetSeconds"):
    config.wallClockBudgetSeconds = node["wallClockBudgetSeconds"].getFloat()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("playerConnectTimeoutSeconds"):
    config.playerConnectTimeoutSeconds =
      node["playerConnectTimeoutSeconds"].getFloat()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("mapPath"):
    config.mapPath = node["mapPath"].getStr()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmAttemptSeconds"):
    config.llmAttemptSeconds = node["llmAttemptSeconds"].getFloat()
  if node.hasKey("llmRetrySeconds"):
    config.llmRetrySeconds = node["llmRetrySeconds"].getFloat()
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool()
  if node.hasKey("gameOverTicks"):
    config.gameOverTicks = node["gameOverTicks"].getInt()
  config.validate()

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config, TOKENS EXCLUDED, as pinned into the replay.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  var roles = newJArray()
  for role in config.roles:
    roles.add(%role)
  %*{
    "num_agents": config.numAgents,
    "turnTicks": config.turnTicks,
    "enrageTicks": config.enrageTicks,
    "maxTicks": config.maxTicks,
    "bossMaxHp": config.bossMaxHp,
    "bossMeleeDamage": BossMeleeDamage,
    "cleaveDamage": CleaveDamage,
    "pourDamage": PourDamage,
    "crucibleDamage": CrucibleDamage,
    "overloadDamage": OverloadDamage,
    "overloadHeal": OverloadHeal,
    "addHp": AddHp,
    "addDamage": AddDamage,
    "roleHp": {"tank": TankMaxHp, "healer": HealerMaxHp, "dps": DpsMaxHp},
    "healAmount": HealAmount,
    "healCost": HealCost,
    "shieldAbsorb": ShieldAbsorb,
    "manaMax": ManaMax,
    "manaRegenPerSecond": ManaRegenPerTick,
    "interruptCooldownTicks": InterruptCooldownTicks,
    "tauntCooldownTicks": TauntCooldownTicks,
    "turnBudgetSeconds": config.turnBudgetSeconds,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "playerConnectTimeoutSeconds": config.playerConnectTimeoutSeconds,
    "mapPath": config.mapPath,
    "roles": roles,
    "players": players
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuilds a config from a replay's pinned config document.
  result = defaultGameConfig()
  result.numAgents = node{"num_agents"}.getInt(Seats)
  result.turnTicks = node{"turnTicks"}.getInt(120)
  result.enrageTicks = node{"enrageTicks"}.getInt(5760)
  result.maxTicks = node{"maxTicks"}.getInt(6480)
  result.bossMaxHp = node{"bossMaxHp"}.getInt(26000)
  result.mapPath = node{"mapPath"}.getStr("foundry")
  let rolesNode = node{"roles"}
  if rolesNode != nil and rolesNode.kind == JArray:
    for role in rolesNode:
      result.roles.add(role.getStr())
  let playersNode = node{"players"}
  if playersNode != nil and playersNode.kind == JArray:
    for player in playersNode:
      result.players.add(PlayerConfig(name: player{"name"}.getStr()))
