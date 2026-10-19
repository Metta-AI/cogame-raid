# Metta post-training data

The native simulator and published `stalwart` policy export private candidate
trajectories for both certified Raid variants. Export requires a clean commit.

```sh
nimby sync nimby.lock
for variant in default sprint; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/raid-${variant}" 10 1 "$variant" mixed 3
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
encounters. At each simultaneous turn, it records every living seat's hosted
system and user prompts and a scripted order accepted by the game's reply
parser. Parsed orders drive the native encounter engine. Whole encounters
share the `raid-SEED` family across game variants and wording selections.
The output manifest records source revision, wording, variant, scores, ending
rule, and row counts. Existing output directories are never overwritten.

`trajectories.jsonl` contains completed episode events and private decision
events. Each decision records the teacher response, parsed order, installed
order, selected attempt, exact messages, and prompt hashes. The shared Coworld
SDK and application importer own review and dataset splits. These candidates
are not ready-to-train datasets; unreviewed examples must not be admitted.

Historical canonical exports yielded 520 training and 247 validation examples
for Default, and 442 and 175 for Sprint. All 1,384 examples fit the
Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 1,913.
These examples distill the scripted teacher; they do not establish stronger
league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.

## Numeric training

The persistent bridge covers Default and Sprint. It exposes 292 fixed
features from each seat's `seatView`: boss state and telegraphs, living raid
members, adds, hazards, cooldowns, meters, and the seat's last order. It
snapshots every living seat before applying the simultaneous orders. Seven
action heads encode intent, target, station, exact point coordinates, point
presence, and telegraph reaction. The production order parser, repairer,
encounter driver, and simulator execute each action. The game gives every
seat the same score; the bridge also supplies bounded utility for learning.
Numeric features record callout presence but omit the free-form callout text.
The target head selects a visible add slot, so new add IDs remain selectable
across waves.

Prompt and trained policies receive the same private seat view and send
complete orders through `raid.player.v2`. The game owns role legality, order
repair, turn deadlines, scripted fallback, results, and replay.

```sh
nim c -d:release --path:src -o:/tmp/raid-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/raid-train-bridge
```

From Metta, use `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` with command
`["/tmp/raid-train-bridge", "<source>/coworld_manifest_template.json", "default"]`
and `players=5`. Replace `default` with `sprint` for the second variant.
Set a finite timestep limit for either trainer.

## Prompt diversity

Reset accepts `promptVariant` and `promptSeed`. `canonical` preserves the
original prompt. `plain`, `numbered`, `questions`, and `reordered` paraphrase
only the introduction. `mixed` chooses one of those five using an explicit
nonnegative prompt seed, independently of the simulation seed. Selection
stays fixed throughout an encounter and its retries.

`heldout-briefing` and `heldout-reference` are evaluation-only wordings.
Bridge resets using them require `split: "validation"` or `split: "test"`;
source export rejects them.
The bridge's optional third argument, `text`, uses the native order parser.
Without that argument it retains the numeric action interface.

```sh
python3 tools/test_prompt_games.py /tmp/raid-train-bridge
```

This system panel compares complete games under each wording in both variants
and interfaces. It verifies unchanged observations, actions, and outcomes.
It does not measure learned policy robustness. A model comparison must hold
simulation seeds, budgets, and policies fixed and report errors and fallbacks
alongside scores, including the two held-out wordings.
