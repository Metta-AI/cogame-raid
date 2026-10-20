# Raid prompt diversity and training

The `raid-rules-v3` bank has five complete training presentations and two
evaluation-only presentations. Wording and order vary arena, roles, phases,
mechanics, coordination, and controller explanations. Action grammar and
strategy hints stay fixed. Alternate and held-out explanations are independently phrased.
Every wording, including canonical, explains the shared kill-speed/health-removed score.
Sprint states 120-second enrage and a 150-second stop from its configuration.
Gameplay budgets remain unchanged.

Set `promptVariant` and `promptSeed`. Mixed selection requires an explicit
nonnegative seed, resolves modulo five, and stays fixed across seats and retries.
The game sends rendered rules through the existing player protocol. Native
inference, the bridge, and exports use the same renderer and sampled configuration.
Training resets and source exports reject held-out wording. Metadata records
selection and exact system/user message hashes.

```sh
python3 tools/test_prompt_games.py BRIDGE
export_posttrain PRIVATE_OUTPUT 10 1 default mixed 0
export_posttrain PRIVATE_OUTPUT 10 1 sprint mixed 0
```

Original train/validation JSONL and manifests are retained. Every fifth scenario
is validation, and wording cycles separately within each split. Scenario families
use `raid-SEED` across variants. Episode IDs include requested selection, resolved wording, and prompt seed. The native parser and encounter engine execute
scripted teacher orders. Export from clean committed source and review content
before training. Existing output directories are refused.

Compare canonical and mixed training with fixed policies, seats, scenario seeds,
operator guidance, decoder settings, and game budgets. Report scores, malformed
responses, retries, and failures by wording. Scripted equivalence does not establish
improved learning stability.

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
