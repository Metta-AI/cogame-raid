# Wire protocol

Two protocols and one file format:

- **`raid.player.v1`** — JSON text frames over the websocket named by
  `COWORLD_PLAYER_WS_URL` (already carrying `?slot=N&token=T`).
- **`raid.global.v1`** — the spectator snapshot pushed over `/global`.
- **`raid.replay.v1`** — the strict UTF-8 JSON replay written to
  `COGAME_SAVE_REPLAY_URI`.

## `raid.player.v1`

A raid policy is a prompt. The player container's only job is to deliver it: the
**game server** makes every decision, because the Bedrock sidecar credentials
and the `anthropic_api_key` coworld secret are injected into the game pod and
"one parallel batch per turn" is a game-server property.

### player → game (exactly once, on connect)

```json
{"type": "register",
 "prompt": "<strategy text or empty>",
 "scripted": "stalwart" | "greenhorn" | null,
 "policy": "<free label, <= 48 runes>"}
```

`prompt` is capped at 4000 runes at the transport (over-long is truncated, not
rejected) and is never written to the replay or the results. A seat that
registers with neither field, or never registers at all, plays the `stalwart`
baseline. `PLAYER_SCRIPTED` parsing: `stalwart`/`1`/`true`/`yes`/`default` →
stalwart, `greenhorn`/`green`/`novice` → greenhorn, anything else → none.

### game → player

On connect:

```json
{"type": "welcome", "protocol": "raid.player.v1", "slot": 2,
 "alias": "Charlie", "turn_seconds": 5.0}
```

Once per decision turn, to every seat (informational — the seat is not required
to answer):

```json
{"type": "turn", "turn": 17, "tick": 2040, "phase": 2,
 "role": "healer", "view": { … }, "order_source": "llm"}
```

A seat that dies receives one turn frame with `view.you.alive == false` and
nothing further until `done`.

At the end, then close:

```json
{"done": true, "result": { …the results document… }}
```

The done broadcast is bounded at 3.0 s per seat.

### The per-seat view

Coordinates are integers (map pixels); times are seconds to one decimal. One
shape for all three roles — role-specific blocks (`mana`, `cooldowns_s`) appear
only where they apply.

```json
{"turn": 17, "of": 54, "tick": 2040, "phase": 2, "phase_name": "Slag",
 "clock": {"elapsed_s": 85.0, "enrage_in_s": 155.0, "hard_end_in_s": 185.0},
 "you": {"alias": "Charlie", "role": "healer", "pos": [742, 402],
         "alive": true, "hp": 132, "max_hp": 160, "shield": 0,
         "mana": 640, "max_mana": 1200, "threat": 1180,
         "attacking": "boss",
         "cooldowns_s": {"heal": 0.0, "shield": 7.5, "attack": 0.3},
         "casting": {"ability": "heal", "target": "Alpha",
                     "remaining_s": 0.4}},
 "boss": {"name": "SMELTER-9", "pos": [617, 329], "facing_brads": 64,
          "hp": 16120, "max_hp": 26000, "hp_pct": 62.0, "phase": 2,
          "target": "Alpha", "enraged": false,
          "buffs": {"feed": true, "spill_stacks": 0},
          "casting": {"ability": "overload", "remaining_s": 2.1,
                      "interruptible": true},
          "next_s": {"cleave": 3.5, "pour": 6.0, "overload": 22.1,
                     "adds": 9.0}},
 "telegraphs": [{"id": 41, "kind": "pour", "shape": "circle",
                 "centre": [520, 430], "radius": 90, "resolves_in_s": 1.4,
                 "soak_needed": 0, "you_are_inside": false}],
 "raid": [{"alias": "Alpha", "role": "tank", "pos": [617, 293],
           "alive": true, "hp": 188, "max_hp": 300, "shield": 60,
           "threat": 41200, "attacking": "boss",
           "last_intent": "tank_boss", "say": "cone is north"}, … 5 … ],
 "adds": [{"id": "A5", "pos": [700, 250], "hp": 140, "max_hp": 220,
           "target": "Alpha"}, … ],
 "pools": [{"id": 12, "centre": [560, 470], "radius": 90,
            "expires_in_s": 4.0}],
 "callouts": [{"alias": "Alpha", "say": "cone is north"}],
 "meters": {"damage_to_boss": [0, 4120, 3980, 4410, 210],
            "healing_done": [0, 0, 0, 0, 5320]},
 "your_last_order": { …the order you played last turn, or null on turn 0… }}
```

**Visible to every seat:** the whole pit; the boss's exact HP, phase, facing,
target, buffs, live cast and the seconds until each of its abilities next fires
(the schedule is deterministic and documented in `docs/RULES.md`, so hiding it
would reward memorisation, not play); every live telegraph with its shape, fuse
and required bodies; every add and pool; all five cogs' positions, HP, shields,
threat, current attack target and last order intent; the running damage and
healing meters; and the four other seats' `say` callouts **from the previous
turn** — the raid's one communication channel, capped at 32 runes, deliberately
public and deliberately one turn stale.

**Hidden from every seat:** the other seats' full orders and their private
`note` text; the episode `seed`; the PCG32 draw for the next pour; the boss's
remaining schedule beyond the published `next_s` figures; every policy's
`PLAYER_PROMPT`; and the **real player names behind the aliases**.

### The order schema

The LLM must return this object; the scripted baselines produce the identical
shape.

```json
{"intent": "heal_target", "target": "Alpha", "station": "ranged",
 "point": [742, 402], "on_telegraph": "dodge",
 "note": "tank is eating cleave plus feed; topping it",
 "say": "tank heals, dodge pours"}
```

| Field | Type | Cap / legal values | Repair when violated |
|---|---|---|---|
| `intent` | enum, ≤ 16 runes | tank: `tank_boss` `taunt` `pick_up_adds` `kite` `soak` `wait`; healer: `heal_lowest` `heal_target` `shield_target` `conserve` `soak` `wait`; dps: `burn_boss` `kill_adds` `interrupt` `assist_target` `soak` `wait` | unknown, or legal for another role → `tank_boss` / `heal_lowest` / `burn_boss` |
| `target` | string / null, ≤ 12 runes | `boss`, `A1`…`A8`, `Alpha`…`Echo`; case-insensitive | unknown id, dead entity, or an id illegal for the intent → the intent's natural target; none available → the intent degrades to `wait` |
| `station` | enum, ≤ 8 runes | `melee` `ranged` `spread` `edge` `point` `soak` | → `melee` for a tank, `ranged` otherwise |
| `point` | `[int, int]` | clamped into the pit (anything beyond 288 px from (617,329) is pulled onto that circle) | missing / non-finite → the cog's current position |
| `on_telegraph` | enum, ≤ 8 runes | `dodge` `hold` `soak` `spread` | → `dodge` |
| `note` | string | ≤ 160 runes | truncated to 160 runes |
| `say` | string | ≤ 32 runes | truncated to 32 runes |

Three further caps on strings that reach the replay: `register.policy` ≤ 48
runes, any recorded error text (`fallback.detail`) ≤ 200 runes, and
`register.prompt` ≤ 4000 runes at the transport.

**Truncation is on rune (Unicode codepoint) boundaries, never bytes.** A
byte-truncated multi-byte character is exactly the bug that makes replay bytes
render in a browser and fail a strict JSON parser.

**Parsing is tolerant:** markdown fences are stripped, the outermost balanced
`{…}` is taken if the model prefixed prose, numeric strings inside `point` are
accepted, and `target` may arrive as an integer 1–8 (read as `A<n>`) or 0 (read
as slot 0's alias). Only when no object with a usable `intent` can be recovered
does the retry, and then the fallback, fire.

### The control layer

The order is compiled to control bytes every tick by the same code for every
policy kind:

1. **Reaction override.** While a telegraph is live and its shape contains (or,
   for `soak`, is the circle to step into) this cog, `on_telegraph` takes over
   the steering point: `dodge` → the nearest point 20 px outside the shape
   (perpendicular to a cone's bisector, on the side with more free floor);
   `hold` → no override; `soak` → the circle's centre; `spread` → 160 px away
   from the centroid of the other living cogs.
2. **Steering point** otherwise, from `intent` and `station`: `melee` = 40 px
   from the target; `ranged` = the 260 px ring from the boss; `spread` = 140 px
   from the nearest cog; `edge` = the 280 px ring; `point` = the named point;
   `soak` = the live pour circle's centre. `kite` walks 120 px away from the
   boss every tick; `wait` stands still.
3. **Move command.** `d = p* − x`; `|d| ≤ 8` → stop; else the integer unit vector
   times 100. **Unstick rule:** a cog whose net displacement over 24 ticks is
   under 6 px while it is commanding movement rotates its heading 45° once a
   second until it moves. There is **no pathfinder**: a station behind a pillar
   is a bad order.
4. **Aim** turns at most 8 brads/tick toward the attack target.
5. **Action bits** as described in `docs/RULES.md` step 3.

## `raid.global.v1`

Spectators connect a websocket to `/global` and receive the whole snapshot as
JSON after every decision turn and at the end:

```json
{"type": "state", "game": "raid", "protocol": "raid.global.v1",
 "tick": 2040, "turn": 17, "ticks_per_second": 24,
 "phase": 2, "phase_name": "Slag",
 "seats": [{slot, alias, name, policy_kind, role, pos, aim, alive, hp,
            max_hp, shield, mana, threat, attacking, intent, note, say,
            source, damage_to_boss, healing_done, damage_taken,
            avoidable_hits, connected} × 5],
 "boss": {name, pos, aim, hp, max_hp, hp_pct, target, enraged, feed,
          spill_stacks, casting, cast_remaining, cast_total},
 "adds": [...], "pools": [...], "telegraphs": [...],
 "enrage_in_s": 155.0, "hard_end_in_s": 185.0,
 "events": [ …the whole append-only transcript… ],
 "done": false, "reason": "", "end_rule": "", "score": 0.0}
```

Real policy names appear here, in the replay and in the results — never in a
seat's view. The browser page at `/client/replay` renders a recorded episode off
the same bundle the platform serves statically.

## `raid.replay.v1`

Strict UTF-8 JSON, self-sufficient: names, colours, config, map geometry, the
phase table, per-tick controls, per-second states with their digests, the whole
event transcript, the seed and the results. The viewer contacts nothing but the
S3 URL it was given.

```json
{"protocol": "raid.replay.v1",
 "format_version": 1,
 "game_version": "1",
 "seed": 679961,
 "config": { …the fully resolved game config, tokens excluded… },
 "map": { …data/foundry.mapspec.json inlined verbatim… },
 "names": {"players": [...], "aliases": [...], "roles": [...],
           "policy_kinds": [...], "colors": {...}},
 "ticks_per_second": 24, "turn_ticks": 120, "tick_count": 4608,
 "phases": [{"phase": 1, "name": "Forge", "from": 0, "to": 1103}, …],
 "controls_b64": "<base64 of tick_count x 5 x 4 bytes:
                   (move_x i8, move_y i8, aim_turn i8, action u8)>",
 "keyframes": [{"t": 0, "d": 2947483111, "cogs": [[…7…] × 5],
                "boss": [x, y, aim, hp, phase, feed, spill],
                "adds": [[id, x, y, hp]], "pools": [[id, cx, cy, r, age]],
                "tel": [[id, kind, cx, cy, r_or_facing, fuse, soak]],
                "mtr": [[dmg_boss, dmg_adds, healing, taken] × 5]}, … ],
 "events": [ … ],
 "results": { … }}
```

A cog keyframe row is `[x, y, aim, hp, shield, mana, state]` with
`state 0 = alive, 1 = casting, 2 = dead`. A telegraph's `kind` is
`0 = cleave, 1 = pour, 2 = crucible`.

`seed` + `map` + `config` + the recorded `order` events + the integer sim
reproduce the encounter exactly; `keyframes` carry the per-second state and its
digest `d` so the viewer, the tests and a human reading the JSON can verify the
re-derivation without running wasm at all. **Auto-attacks and pool ticks are
deliberately not evented** (~1500 records a minute would drown the feed); they
ride in the per-second keyframe meters. Every damage instance of 40 or more, and
every death, is evented.

### Event vocabulary

Every record carries `t` (the tick) and `type`.

| `type` | Fields |
|---|---|
| `encounter_start` | `seed`, `aliases`, `roles`, `boss_max_hp`, `enrage_s`, `hard_end_s` |
| `phase_start` | `phase`, `name`, `boss_hp`, `boss_hp_pct`, `elapsed_s` |
| `turn_start` | `turn`, `boss_hp_pct`, `alive`, `enrage_in_s` |
| `order` | `turn`, `seat`, `alias`, `role`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `intent`, `target`, `station`, `point`, `on_telegraph`, `note`, `say` |
| `fallback` | `turn`, `seat`, `alias`, `attempt`, `cause`, `detail` |
| `budget_guard` | `turn`, `remaining_s` |
| `cast_start` | `ability`, `cast_ticks`, `interruptible` |
| `telegraph` | `id`, `kind`, `centre`, `radius` or `facing_brads`+`half_angle_brads`+`reach`, `fuse_ticks`, `soak_needed`, `drawn_on` |
| `telegraph_resolve` | `id`, `kind`, `hit`, `damage_each`, `soakers`, `spill_gained`, `pool_id` |
| `interrupt` | `seat`, `alias`, `ability`, `result` (`success`\|`wasted`\|`late`\|`out_of_range`) |
| `taunt` | `seat`, `alias`, `result` (`pulled`\|`already_target`\|`out_of_range`) |
| `heal` | `seat`, `alias`, `target`, `amount`, `overheal`, `mana_left`, `result` (`applied`\|`cancelled`), `why` |
| `shield` | `seat`, `alias`, `target`, `absorb` |
| `adds_spawn` | `wave`, `ids`, `positions`, `alive_after` |
| `add_death` | `id`, `killer`, `alive_after` |
| `feed_buff` | `active`, `adds_alive` |
| `boss_hit` | `target`, `ability`, `amount`, `absorbed`, `hp_left` — `target` is a cog alias, except for the single aggregate record a resolved Overload adds after its five per-cog ones, where it is `"raid"` |
| `boss_damaged` | `seat`, `alias`, `amount`, `boss_hp`, `boss_hp_pct` — only when a hit crosses a 5 % boss-HP boundary |
| `pool_spawn` / `pool_expire` | `id`, `centre`, `radius` |
| `death` | `alias`, `role`, `killer`, `elapsed_s`, `alive_left` |
| `enrage` | `elapsed_s`, `boss_hp_pct` |
| `end` | `reason`, `end_rule`, `boss_hp_removed_frac`, `elapsed_s`, `charged_s`, `score`, `phase_reached`, `alive_at_end`, `meters` |

## The results document

Per-seat arrays are length 5 in slot order. This key set is closed and must
equal the manifest's `results_schema` key for key.

```json
{"names": [...], "aliases": [...], "roles": [...], "policy_kinds": [...],
 "scores": [1.25, 1.25, 1.25, 1.25, 1.25],
 "boss_hp_removed": 26000, "boss_max_hp": 26000,
 "boss_hp_removed_frac": 1.0,
 "elapsed_seconds": 192.0, "charged_seconds": 192.0,
 "enrage_seconds": 240.0, "phase_reached": 3,
 "kill": true, "wipe": false, "deaths": 1, "alive_at_end": 4,
 "damage_to_boss": [...], "damage_to_adds": [...], "healing_done": [...],
 "overhealing": [...], "damage_taken": [...], "avoidable_hits": [...],
 "interrupts_landed": [...], "interrupts_wasted": [...],
 "overloads_resolved": 1, "adds_killed": 8, "spill_stacks": 0,
 "reason": "complete", "end_rule": "kill",
 "final_tick": 4608, "final_turn": 39, "seed": 679961,
 "llm_turns": [...], "fallback_turns": [...],
 "fallback_causes": [{"timeout": 0, "parse_error": 0,
                      "transport_error": 0, "no_credentials": 0,
                      "budget_guard": 0}, … 5 … ]}
```

## Runtime contract

The game container honours `bitworld/runtime`: `COGAME_CONFIG_URI`,
`COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`, `COGAME_LOAD_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, plus `COGAME_EVENTS_URI` and `COGAME_METRICS_URI`
which are **`file://`-only and loudly rejected otherwise**. Routes:
`GET /healthz`, `GET /client/replay`, `GET /client/<asset>`,
`GET /replay-data` (replay mode), `WS /player?slot=N&token=T` (403 on a bad
slot/token, 409 on a duplicate connection), `WS /global`.
