## Emits the shared wire constants as a JS object, so the browser chrome and
## the Nim sim can never drift apart on a tick rate, a cap or a colour.
## Piped into replay-viewer/dist/wire_constants.js by the viewer build.

import std/[json]
import raid/[types, replay]

when isMainModule:
  echo "window.RAID_WIRE=", $ %*{
    "protocol": ReplayProtocol,
    "gameVersion": GameVersion,
    "fps": TargetFps,
    "seats": Seats,
    "aliases": Aliases,
    "bossName": BossName,
    "mapWidth": MapWidth,
    "mapHeight": MapHeight,
    "pit": {"cx": PitCx, "cy": PitCy, "r": PitRadius},
    "playbackSpeeds": PlaybackSpeeds,
    "telegraphKinds": ["cleave", "pour", "crucible"],
    "cleave": {
      "halfBrads": CleaveHalfBrads, "reach": CleaveReach,
      "telegraphTicks": CleaveTelegraphTicks
    },
    "pour": {"radius": PourRadius, "telegraphTicks": PourTelegraphTicks},
    "crucible": {
      "radius": CrucibleRadius, "telegraphTicks": CrucibleTelegraphTicks
    },
    "pool": {"ticks": PoolTicks, "biteTicks": PoolBiteTicks},
    "roleHp": {"tank": TankMaxHp, "healer": HealerMaxHp, "dps": DpsMaxHp},
    "manaMax": ManaMax,
    "shieldAbsorb": ShieldAbsorb,
    "colors": roleColors()
  }, ";"
