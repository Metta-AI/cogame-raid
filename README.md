# raid — five strangers versus one scripted boss

**A policy is just a prompt.** Five cogs who have never met are dealt a tank, a
healer and three damage roles and thrown at **SMELTER-9**, a fully scripted
foundry boss with three authored phases, telegraphed floor mechanics, adds, an
interruptible cast and a hard enrage timer. The opponent never varies; the only
variable is how well five strangers coordinate.

Score is boss health removed ÷ time spent, in units of the enrage timer —
**1.0 means "killed it exactly on the 240-second timer"** — and every seat
carries the identical number, so a healer who never touches the boss can be a
champion.

* Rules, every number: [`docs/RULES.md`](docs/RULES.md)
* Wire protocol, schemas and the event vocabulary:
  [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
* Design note: [`docs/plans/2026-08-23-raid-design.md`](docs/plans/2026-08-23-raid-design.md)

## The encounter in one screen

SMELTER-9 is bolted to the centre of a 300 px round pit with four sight-blocking
pillars. It swings at its highest-threat cog every 1.5 s, and:

- **Cleave** — a 90° cone 180 px in front of it, telegraphed 2 s. Only the tank
  should be in it, and its facing is FROZEN for the whole telegraph, so a
  side-step works.
- **Slag Pour** — a 90 px circle dropped on a random non-tank, telegraphed
  2.5 s, leaving a burning pool for 10 s.
- **Crucible Pour** (phase 3) — a 110 px circle telegraphed 3 s carrying 240
  damage **split between everyone standing in it**. One dps alone dies; two eat
  it cheaply; nobody at all and the boss keeps a permanent +20 % damage stack.
- **Overload** (phases 2–3) — a 4 s cast that hits all five for 70 and heals the
  boss 400 unless ONE dps interrupts it. Two interrupts on the same cast wastes
  one, so the raid has to actually assign the job.
- **Slag Crawlers** — pairs of adds through phase 2; at four or more alive the
  boss deals +25 % more damage.

At 240 s it **enrages** (triple damage) and the pull is hard-stopped at 270 s.

## A policy is a prompt

Every five seconds each living seat issues **one order** — an intent, a target,
a station, a point and, crucially, the reaction it pre-authorises for the next
telegraph — and a deterministic control layer executes it at 24 Hz. You do not
drive motors; you choose the reaction, not the dodge.

```json
{"intent": "heal_target", "target": "Alpha", "station": "ranged",
 "point": [742, 402], "on_telegraph": "dodge",
 "note": "tank is eating cleave plus feed; topping it",
 "say": "tank heals, dodge pours"}
```

Field your own policy by reusing the published player runnable with a different
`PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-raid:latest --name my-raid \
  --run /bin/raid-player \
  --secret-env PLAYER_PROMPT="<your strategy for all three roles>"
```

Your role is **dealt** each episode, so a prompt has to cover tank, healer and
dps. Your only channel to the other four is `say` — 32 characters, public, and
one turn stale.

Decisions are made in the **game server**, which sends every living seat's
prompt plus its view to Claude as **one parallel batch per turn**. With no LLM
credentials at all the server plays the built-in `stalwart` baseline for every
seat, so offline certification always completes.

## Two scripted baselines

Both are fieldable policies and both play through exactly the same control
layer as an LLM seat, so they are directly comparable.

- **`stalwart`** — the certification player and the default: the tank holds the
  boss north of the stand so the cone points at empty floor, the healer triages
  by missing hit points from a pool-free stand, one dps owns the Overload
  interrupt for the whole fight, the rest clear crawlers, and in Meltdown the
  raid stacks so a crucible splits three ways.
- **`greenhorn`** — deliberately weaker and different in shape: everyone stands
  in melee, everyone dodges everything (so the tank walks its own cleave across
  the raid), nobody interrupts, nobody soaks, adds are ignored. A clean floor for
  the ladder.

```bash
PLAYER_SCRIPTED=stalwart   /bin/raid-player
PLAYER_SCRIPTED=greenhorn  /bin/raid-player
```

## Watching

The replay is a **static wasm bundle**, never a pod: the browser re-derives
every frame from `seed` + `map` + `config` + the recorded orders with the same
Nim sim the server runs, and checks itself against the per-second state digests
in the replay. The chrome is paintbot's, with a boss health bar carrying phase
ticks at 70 % and 35 %, five role nameplates, telegraphed AoE decals that fill
from the edge inward as the fuse burns, an enrage clock, an Overload cast bar
with the interrupt prompt, and a damage/healing endcard.

## Building

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim c -d:release --out:raid src/raid.nim
nim c -d:release --out:raid-player src/raid_player.nim
nim r --path:src tests/test_boss.nim        # any tests/*.nim, standalone
./tools/ci/docker_smoke.sh coworld-raid:ci  # one real episode in raw docker
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
python3 scripts/art/gen_raid_art.py data/art
python3 tools/build_manifest.py             # regenerates the manifest template
```

The committed `nim.cfg` is host-specific and gitignored; regenerate it from
`~/.nimby/pkgs` exactly as the Dockerfile does.

MIT licensed.
