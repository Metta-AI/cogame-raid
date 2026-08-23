## Raid entrypoint: reads the Coworld runtime contract and starts either a
## live episode server or a replay viewer server.
##
## Seed randomisation happens HERE, before `config.update`'s pinned seed is
## honoured, so every seed-derived draw - the role deal and the pour target
## draws - follows the FINAL seed (paintbot's rule, `src/ctf.nim:7-46`).

import std/[json, strutils, sysrand]
import bitworld/runtime
import raid/config
import raid/types
import raid/server

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(RaidError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("raid: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
      quit("raid: COGAME_CONFIG_URI is required (no game config was given)", 2)
    var config = defaultGameConfig()
    try:
      config.update(runtimeConfig.config)
    except CatchableError as error:
      quit("raid: invalid game config: " & error.msg, 2)
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "raid: seed not pinned; randomized to ", config.seed
    if config.tokens.len == 0:
      quit("raid: the game config must carry one token per seat", 2)
    if config.players.len != config.numAgents:
      quit("raid: the game config must name " & $config.numAgents &
        " players", 2)
    echo "raid: seats=", config.numAgents,
      " boss=", config.bossMaxHp,
      " enrage=", config.enrageTicks,
      " maxTicks=", config.maxTicks,
      " map=", config.mapPath,
      " model=", config.model
    try:
      runGameServer(config, runtimeConfig)
    except CatchableError as error:
      quit("raid: " & error.msg, 2)
