# Agent operating guide — cogame-raid

Orientation for coding agents. Gameplay rules live in
[docs/RULES.md](docs/RULES.md), the wire formats in
[docs/PROTOCOL.md](docs/PROTOCOL.md), and the design that produced both in
[docs/plans/2026-08-23-raid-design.md](docs/plans/2026-08-23-raid-design.md).

## Layout

- `src/raid.nim` — entrypoint. **Seed randomisation happens here**, before the
  pinned seed is honoured, so every seed-derived draw (the role deal, the pour
  target draws) follows the final seed.
- `src/raid_player.nim` — the thin policy-delivery player. It never decides
  anything.
- `src/raid/` — `types.nim` (constants, the wire types, the integer brad
  tables), `config.nim`, `arena.nim` (the map bake and the occupancy prefix
  sums), `state.nim` (the `Sim` object and the digest), `combat.nim`,
  `pools.nim`, `telegraphs.nim`, `abilities.nim`, `boss.nim`, `control.nim`,
  `orders.nim`, `baselines.nim`, `scoring.nim`, `sim.nim` (the step loop, which
  re-exports the rest), `replay.nim`, `broadcast.nim`, `engine.nim` (the turn
  loop), `llm.nim`, `server.nim`, `labels.nim`, `events.nim`. The design note's
  `roster.nim` and `render.nim` were never built: seat join, auth and slot
  handling live in `server.nim`, and rendering lives in
  `client/broadcast_core.js` and the wasm viewer.
- `tests/` — every file is a standalone program; `tests/support/` holds the
  shared helpers so the `tests/*.nim` glob never runs one.

## The inviolable property

**Same seed + same control bytes ⇒ same digest at every keyframe, natively and
under emscripten.** That holds only because the whole step is integer: no
`sin`, `cos`, `tan`, `atan2`, `pow`, `exp`, `ln`, `fmod`, `hypot` or square
root, and no floating-point value at all in the step path. `tests/
test_determinism.nim` greps for every one of them, and for `-ffast-math` in the
build scripts. If you need an angle, compare brads; if you need a distance,
compare squares; if you need a unit vector, use `scaleToLength`.

Bump `GameVersion` in `src/raid/types.nim` whenever a recorded control byte
would re-derive a different encounter, and re-record
`tests/fixtures/golden_digests.json` with `tools/record_golden.nim` in the same
commit.

## Generated files

Three files are generated and must be regenerated rather than edited:

```bash
python3 tools/build_manifest.py          # coworld_manifest_template.json
python3 scripts/art/gen_raid_art.py data/art && cp data/art/* client/art/
nim r --path:src --path:tests tools/record_golden.nim
```

The manifest inlines README.md, docs/RULES.md and docs/PROTOCOL.md, so editing
a doc without re-running the builder leaves the coworld page stale — and
`tests/test_manifest.nim` will not catch that, only the key set.

## Two name spaces

Prompts and observations see only `Alpha`…`Echo`. Real policy names appear in
`replay.names.players`, `results.names`, the `/global` snapshot and the viewer
chrome — nowhere else. `tests/test_view.nim` greps a seat's view for every real
name, the seed, other seats' notes and prompt text.

## Rune boundaries

Every string that can reach the replay, the results or another seat's callouts
goes through `labels.runeCap`. Never slice a string by byte index on those
paths: a byte-truncated multi-byte character renders in a browser and then
fails a strict JSON parser, which is how a hosted replay becomes unreadable.

## CI is the harness

`ci.yml` runs every `tests/*.nim` twice (debug and `-d:release`), builds the
production image and runs one real episode in raw docker from the certification
fixture, and builds the static replay bundle. `tools/build_replay_viewer.sh`
and `tools/ci/docker_smoke.sh` must stay mode 100755 — `coworld build` refuses
to package a source replay-viewer bundle unless the hook is `os.X_OK`.
