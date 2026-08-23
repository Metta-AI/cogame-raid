# SMELTER-9 — the full boss script

Raid is five cogs against one scripted boss in a round foundry pit, on a
240-second enrage clock. Slots are dealt one tank, one healer and three dps.
The boss never adapts: it runs this published, deterministic script. Everything
the raid can do wrong — standing in the cleave, letting a pour go unsoaked,
missing the Overload interrupt, leaving adds alive, letting the tank die — is a
coordination failure between five policies that have never met.

## Seats and roles

- **`num_agents` = 5.** One seat = one cog. Slots 0–4 map to the aliases
  `Alpha`, `Bravo`, `Charlie`, `Delta`, `Echo`. Those are the only names a
  prompt or an observation ever contains.
- **Roles are dealt.** At episode start the sim shuffles
  `["tank", "healer", "dps", "dps", "dps"]` with a Fisher–Yates pass driven by
  the episode PCG32 stream and assigns the result to slots 0–4. The optional
  config key `roles` (exactly five role strings) overrides the deal outright —
  used by the certification fixture and by every test. A seat learns its role
  in its first observation and it never changes, so **a policy prompt must
  cover all three roles.**
- The boss is `SMELTER-9`; adds are `A1`…`A8` in spawn order.

## The arena

- Floor 1235 × 659 px, origin top-left, +x right, +y down. Everything outside a
  disc of **radius 300 px centred on (617, 329)** is solid wall. The pit is the
  whole game.
- **Four solid 40 × 40 pillars** centred at (511, 223) (723, 223) (511, 435)
  (723, 435). They block movement **and line of sight** — a ranged attack, an
  interrupt and a heal all need a clear line — but they do **not** block cleaves
  or pours, which are floor effects. Hiding behind a pillar stops you being
  healed; that is the point.
- **Boss stand** at (617, 329), a 56 × 56 body. It is solid to cogs and adds and
  transparent to sight.
- **Cog spawns**, slot-ascending, on the south arc: (497,545) (557,561)
  (617,567) (677,561) (737,545).
- **Add alcoves** on the rim at radius 280: (419,131) (815,131) (419,527)
  (815,527).
- **No fog of war.** Every seat sees the whole pit, every cog, the boss, every
  add, every pool and every live telegraph.

## Bodies and motion

| | value |
|---|---|
| cog half-extent | 6 px (12 × 12 footprint) |
| sub-pixel motion scale | 256 |
| acceleration | 76 per tick, scaled by \|move\|/100 per axis |
| friction | ×144/256 on an axis with no input |
| stop threshold | 8 |
| max speed | **832** (3.25 px/tick ≈ 78 px/s) |
| cog–cog restitution | 40 % |
| wall slide scan | 3 px |
| aim | brads, 256 per turn, 0 = east, counter-clockwise; ≤ 8 brads/tick |

The control byte pair is `move_x`, `move_y` ∈ −100…100. The step scales `Accel`
by `|move_a|/100` on each axis and clamps that axis's speed to
`MaxSpeed × |move_a|/100`, so a diagonal is not faster than a cardinal.

Aim is cosmetic for cogs — a cog's attacks hit their chosen target, not wherever
they point. **The boss's aim is not cosmetic:** its cleave cone comes from its
facing.

## Roles, abilities and resources

| | **Tank** | **Healer** | **DPS** (×3) |
|---|---|---|---|
| Max HP | **300** | **160** | **180** |
| Attack range | 40 px (melee) | 300 px | 420 px |
| Attack cooldown | 12 ticks (0.5 s) | 24 ticks (1.0 s) | 18 ticks (0.75 s) |
| Attack damage | 12 | 8 | 34 |
| Threat per damage | **×3** | ×1 | ×1 |
| Signature | **Taunt** | **Heal**, **Shield** | **Interrupt** |

- **Attack** is automatic: the control layer holds the attack bit whenever the
  order's target is alive, in range and line-of-sight clear and the cooldown is
  at 0. The order chooses *what* to hit.
- **Taunt** (tank): range 200 px, cooldown 192 ticks (8 s), instant. Sets the
  tank's threat to 1.15 × the highest current threat and locks the boss's target
  to the tank for 72 ticks (3 s). A taunt fired while the tank already holds the
  target still burns the cooldown and records `taunt{result:"already_target"}`.
- **Heal** (healer): range 360 px, line of sight required, cast 24 ticks (1.0 s),
  heals 90 HP, costs 60 mana, no cooldown. Cancelled (mana refunded) if the
  healer moves more than 8 px, the target dies, or the line breaks. Overheal is
  recorded and wasted. Healing adds 0.25 threat per HP actually healed.
- **Shield** (healer): instant, range 360 px, 120 absorb on one ally, costs 150
  mana, cooldown 360 ticks (15 s), expires after 480 ticks if unspent.
- **Mana** (healer only): 1200 max, +30 on every tick where `t mod 24 == 0`, so
  the sustained ceiling is 45 HP/s of healing and the pool is a burst reserve
  worth ~20 extra heals. Triage is forced.
- **Interrupt** (dps): instant, range 420 px, line of sight required, cooldown
  480 ticks (20 s). Cancels an interruptible boss cast. If two interrupts land on
  the same cast in the same tick, the **lower slot index wins** and the other
  records `interrupt{result:"wasted"}` with its cooldown burned.
- **Death is final.** No resurrection, no respawn. A dead cog is inert, is not
  asked for an order, and stops accruing anything. Five deaths is a wipe.

## SMELTER-9

`bossMaxHp = 26000` in the default variant. Body 56 × 56 at (617, 329); the boss
**never moves**. It faces its current target, turning at most 6 brads/tick,
except during a cleave telegraph, when **its facing is frozen** — that is what
makes side-stepping work.

**Threat and targeting.** Every point of damage dealt to the boss adds threat
(tank ×3); every HP healed adds 0.25 threat to the healer. On every tick where
`t mod 24 == 0` the boss retargets to the highest-threat living cog, but only if
that cog's threat exceeds the current target's by **more than 10 %**. A taunt
overrides both rules for 72 ticks.

**Boss melee.** Every 36 ticks (1.5 s), 55 damage to its current target if that
cog is within 60 px; out of reach the swing whiffs and is still recorded.

### Phases (by boss HP, checked every tick, one-way)

| Phase | Boss HP | Name | What is on |
|---|---|---|---|
| **1** | 100 % → 70 % | *Forge* | melee, Cleave, Slag Pour |
| **2** | 70 % → 35 % | *Slag* | + Slag Crawler waves, + Overload |
| **3** | 35 % → 0 % | *Meltdown* | melee, Cleave (faster), **Crucible Pour** replaces Slag Pour, Overload, one add wave at entry |
| **Enrage** | any, at `t ≥ 5760` (240 s) | *Enrage* | boss damage **×3**, melee period 36 → 24 ticks; permanent |

A phase transition zeroes every ability's schedule counter and restarts it,
emits `phase_start`, and (entering 2 or 3) spawns an add wave immediately.

### Ability 1 — Cleave (all phases)

A frontal cone: **±32 brads (±45°) around the boss's frozen facing, reach
180 px**. **Telegraph 48 ticks (2.0 s)** — the cone is drawn on the floor from
the tick the cast starts. On resolution: **120 damage** to every living cog
whose body centre is inside. Cadence from the previous cleave's resolution:
**192 ticks (8 s) in phase 1, 168 (7 s) in phase 2, 144 (6 s) in phase 3.** The
first cleave starts at tick 96.

### Ability 2 — Slag Pour (phases 1 and 2)

At cast start the boss draws one living **non-tank** cog uniformly from the
episode PCG32 stream and stamps a circle of **radius 90 px** on that cog's
position at that instant. **Telegraph 60 ticks (2.5 s).** On resolution:
**80 damage** to every living cog inside, and a **slag pool** of radius 90 px is
left for **240 ticks (10 s)**, dealing **12 damage** to every cog inside it on
every 24th tick after the pool's spawn tick. At most **6** pools exist; a seventh
expires the oldest. Cadence from the previous resolution: **240 ticks (10 s)
phase 1, 216 (9 s) phase 2.** First pour at tick 192.

### Ability 3 — Crucible Pour (phase 3 only; replaces Slag Pour)

Same draw, **radius 110 px**, **telegraph 72 ticks (3.0 s)**, cadence **168 ticks
(7 s)**. On resolution, let `k` be the number of living cogs whose body centre is
inside:

- `k == 0` → nobody soaked: the boss gains one permanent **Spill** stack,
  **+20 % boss damage each, maximum 5 stacks**, and no pool is left.
- `k ≥ 1` → **240 damage split evenly**, `240 div k` to each (240 alone, 120 each
  for two, 80 for three), and a 240-tick pool is left.

One dps alone dies to it; the tank alone survives it and then needs a heal; two
cogs eat it cheaply. This is the mechanic that most rewards five strangers
agreeing on something in advance.

### Ability 4 — Overload (phases 2 and 3)

A **96-tick (4.0 s) cast** with a visible cast bar, started every **480 ticks
(20 s)** measured from the phase's entry tick. **Interruptible.** If it
completes: **70 damage to all five cogs** and the boss **heals 400 HP** (which
can push it back above a phase threshold in HP but never re-enters a phase). If
interrupted, the cast is cancelled and the next Overload is scheduled 480 ticks
from the cancellation.

### Ability 5 — Slag Crawlers (the adds)

Phase 2, plus one wave at phase-3 entry. At phase-2 entry and every **360 ticks
(15 s)** while in phase 2, **2 crawlers** spawn at the two alcoves furthest from
the current boss target. A crawler: **220 HP**, max speed 640 (2.5 px/tick), body
16 × 16, melee **range 30 px**, **18 damage every 24 ticks**, no ranged attack.
It targets the highest-threat cog within 400 px, else the nearest living cog,
retargeting every 24 ticks. Crawlers take player damage normally and give no
threat on the boss. **Cap 8 alive.** While **4 or more** crawlers are alive the
boss gains **+25 % damage** (`feed_buff` events on both edges).

### Damage multiplier order

`final = base × (1 + 0.25·feed) × (1 + 0.20·spill_stacks) × (3 if enraged
else 1)`, integer-truncated at the end. It applies to every boss-sourced damage
instance — melee, cleave, pour, crucible, Overload and pool ticks — and not to a
crawler's own bite.

## Time and turns

`dt = 1/24 s`.

| | Default variant | Sprint variant |
|---|---|---|
| `turnTicks` (decision turn) | 120 ticks = 5.0 s | 120 |
| `enrageTicks` | 5760 = 240 s | 2880 = 120 s |
| `maxTicks` (hard end) | 6480 = 270 s | 3600 = 150 s |
| `bossMaxHp` | 26000 | 13000 |
| decision turns, maximum | 54 | 30 |

A **decision turn** is 120 ticks. At the first tick of a turn the server freezes
the state, builds a view for every **living** seat, collects one **order** each,
and hands them to the deterministic control layer, which drives the cogs for all
120 ticks. Dead seats are not queried.

## Resolution order (exact, per tick `t`)

"Seat order" always means ascending slot index 0…4; "add order" means ascending
add id.

1. **Clock.** If `t == enrageTicks`, set `enraged` and emit `enrage`.
2. **Control compile.** For each living cog in seat order the control layer reads
   the world and the seat's active order and produces
   `(move_x, move_y, aim_turn, action)`. A dead cog produces `(0, 0, 0, 0)`.
3. **Quantise and record.** `move_x`, `move_y` → `int8` in −100…100; `aim_turn` →
   `int8` clamped to ±8; `action` → a `uint8` bitfield
   (`bit0 attack`, `bit1 taunt`, `bit2 heal`, `bit3 shield`, `bit4 interrupt`).
   **These bytes are the whole input record.**
4. **Aim.** Cogs turn, then the boss turns at most 6 brads toward its target
   unless a cleave telegraph is live, then each add faces its target.
5. **Cog motion**, in seat order, then **6. add motion** in add order.
7. **Timers.** Cooldowns down, casts on, pools and telegraphs age, and on
   `t mod 24 == 0` the healer gains 30 mana (cap 1200).
8. **Player abilities**, in this fixed sub-order so races are decidable:
   (a) interrupt (seat order; lowest slot wins a tie), (b) taunt, (c) shield,
   (d) heal completion, (e) attacks (seat order).
9. **Threat.** This tick's damage and healing fold into the threat table.
10. **Boss retarget** on `t mod 24 == 0`, not while a taunt lock is live.
11. **Boss scheduling.** A finished Overload lands; then, if no cast or telegraph
    is live and a cadence counter has expired, the highest-priority available
    ability starts, in the order **Overload > Crucible/Slag Pour > Cleave**.
12. **Telegraph resolution**, in creation order.
13. **Pools** bite and expire.
14. **Boss and add attacks.**
15. **Deaths.**
16. **Phase check.**
17. **Meters.**
18. **Keyframe** on `t mod 24 == 0`.
19. **End check**, in order: boss dead → `complete/kill`; all five cogs dead →
    `complete/wipe`; `t + 1 == maxTicks` → `complete/enrage_timeout`; wall-clock
    budget exceeded → `deadline/wall_clock`.

## Scoring

```
removed  = bossMaxHp - max(0, bossHpFinal)
f        = removed / bossMaxHp                     in [0, 1]
T        = enrageTicks / 24            = 240.0 s
elapsed  = finalTick / 24
charged  = elapsed   if end_rule == "kill"
         = T         for every other ending
score    = clamp(f * T / charged, 0.0, 3.0)
results.scores = [score, score, score, score, score]
```

**Higher is better.** `score` is "boss health removed ÷ time spent", in units of
the enrage timer, so **1.0 means "killed it exactly on the enrage timer"**.
Faster kills score above 1.0; anything that is not a kill scores the fraction of
the boss it removed, because the raid consumed the whole attempt.

| Ending | `f` | `elapsed` | `charged` | score |
|---|---|---|---|---|
| Clean kill at 192 s | 1.00 | 192.0 | 192.0 | **1.250** |
| Kill 4 s into enrage, 244 s | 1.00 | 244.0 | 244.0 | **0.984** |
| Wipe at 150 s with 71 % removed | 0.71 | 150.0 | 240.0 | **0.710** |
| Survived to the 270 s hard end at 88 % | 0.88 | 270.0 | 240.0 | **0.880** |
| Wall-clock deadline at 130 s, 44 % removed | 0.44 | 130.0 | 240.0 | **0.440** |
| Instant faceplant: wipe at 12 s, 3 % removed | 0.03 | 12.0 | 240.0 | **0.030** |

**Every seat carries the identical score** — the idea's "shared equally", and the
reason a healer who never damages the boss can still be a champion. The per-seat
meters (damage, healing, avoidable hits) are recorded for the endcard and for
humans, and are **not** part of the score.

**What the league ranks by:** the seat's mean `results.scores` value across its
episodes. Elo is wrong here — with five identical scores every episode is a
five-way draw.

## End conditions

`results.reason` is a closed enum of exactly three values; `results.end_rule`
carries the detail and is a closed enum of exactly five.

| `reason` | `end_rule` | When |
|---|---|---|
| `complete` | `kill` | Boss HP ≤ 0. The good ending. |
| `complete` | `wipe` | All five cogs dead. |
| `complete` | `enrage_timeout` | `maxTicks` reached with the boss alive. |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` elapsed first. Declared acceptable: the hosted LLM was slow, not the game broken, and the replay is complete up to the stop tick. |
| `fault` | `sim_fault` | A sim invariant guard tripped. |
| `fault` | `host_error` | An unexpected server-side exception. |

A seat that never connects does **not** end the episode: its cog is driven by the
`stalwart` scripted baseline for the whole encounter, the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, and the raid plays on.

## League operations (recorded, not sim logic)

The integrity clause is a scheduling requirement on the ladder, and the sim is
deliberately blind to it: (a) the five seats of an episode must be drawn from
**five different accounts**; (b) a seat's ranking figure is its **cross-play
mean**, computed over episodes whose teammate mix varies, and must **include
episodes seated with the frozen scripted baselines** so that a policy which only
performs alongside its own twin is visible as such. The game container has no
notion of accounts, and no rule here depends on one.
