# Metta post-training data

The native simulator and published `stalwart` policy export supervised
examples for both certified Raid variants:

```sh
nimby sync nimby.lock
for variant in default sprint; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/raid-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
encounters. At each simultaneous turn, it records every living seat's hosted
system and user prompts and a scripted order accepted by the game's reply
parser. Parsed orders drive the native encounter engine. Whole encounters
stay in one split. The output manifest records source revision, variant,
scores, ending rule, and row counts. Existing output directories are never
overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/raid-default \
  --output /tmp/raid-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete encounters yielded 520 training and 247 validation examples
for Default, and 442 and 175 for Sprint. All 1,384 examples fit the
Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 1,913.
These examples distill the scripted teacher; they do not establish stronger
league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.
