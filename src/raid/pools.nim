## Slag pools: paintbot's `updatePuddles` occupancy hazard with the RNG roll
## removed. A raid pool bites every second, deterministically.

import std/[json]
import types, state, combat

proc spawnPool*(sim: var Sim, cx, cy, radius: int): int =
  ## Adds a pool, expiring the oldest when the cap is already met.
  while sim.pools.len >= PoolCap:
    let dead = sim.pools[0]
    sim.pools.delete(0)
    sim.record("pool_expire", %*{
      "id": dead.id, "centre": [dead.cx, dead.cy], "radius": dead.radius
    })
  let id = sim.nextPoolId
  sim.nextPoolId.inc
  sim.pools.add(Pool(id: id, cx: cx, cy: cy, radius: radius,
    spawnTick: sim.tick, alive: true))
  sim.record("pool_spawn", %*{
    "id": id, "centre": [cx, cy], "radius": radius
  })
  id

proc updatePools*(sim: var Sim) =
  ## Step 13 of the tick: bite, then expire.
  for i in 0 ..< sim.pools.len:
    let pool = sim.pools[i]
    let age = sim.tick - pool.spawnTick
    if age <= 0 or age mod PoolBiteTicks != 0:
      continue
    let bite = sim.damageMultiplied(PoolDamage)
    for slot in 0 ..< sim.cogs.len:
      if not sim.cogs[slot].alive:
        continue
      if withinPx(sim.cogs[slot].x, sim.cogs[slot].y, pool.cx, pool.cy,
          pool.radius):
        discard sim.damageCog(slot, bite, "pool", "pool")
  var kept: seq[Pool]
  for pool in sim.pools:
    if sim.tick - pool.spawnTick >= PoolTicks:
      sim.record("pool_expire", %*{
        "id": pool.id, "centre": [pool.cx, pool.cy], "radius": pool.radius
      })
    else:
      kept.add(pool)
  sim.pools = kept
