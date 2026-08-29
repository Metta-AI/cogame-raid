## Emits the shared wire constants as a JS object, so the browser chrome and
## the Nim sim can never drift apart on a tick rate, a cap or a colour.
## Piped into replay-viewer/dist/wire_constants.js by the viewer build.

import std/[json, sequtils]
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
    # Half speed is a VIEWER concern, so it is prepended here rather than in
    # types.nim: the step path is integer-only and its float-literal guard
    # (tests/test_determinism.nim) forbids a 0.5 in that module.
    "playbackSpeeds": @[0.5] & PlaybackSpeeds.mapIt(it.float),
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
