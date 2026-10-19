"""Compare full Raid encounters, requests, and actions across wording selections."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(
    binary: Path,
    manifest: Path,
    variant: str,
    text_mode: bool,
    wording: str,
    prompt_seed: int,
    seed: int,
    original: bool = False,
) -> tuple[str, str]:
    command = [str(binary), str(manifest), variant] + (["text"] if text_mode else [])
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    input_stream, output_stream = process.stdin, process.stdout
    assert input_stream is not None and output_stream is not None
    digest = hashlib.sha256()
    exact = hashlib.sha256()

    def request(value: dict) -> dict:
        input_stream.write(json.dumps(value) + "\n")
        input_stream.flush()
        return json.loads(output_stream.readline())

    def record(value: dict) -> None:
        digest.update(json.dumps(value, sort_keys=True).encode())

    try:
        reset = {"kind": "reset", "players": 5, "seed": f"raid-{seed}"}
        if not original:
            reset.update(promptVariant=wording, promptSeed=prompt_seed, split="validation")
        observation = request(reset)
        selected = WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
        first_system = None
        decisions = 0
        roles = set()
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            system, user = [m["content"] for m in observation["messages"]]
            if not original:
                assert view.pop("prompt_template") == {
                    "bank": "raid-rules-v2",
                    "selection": wording,
                    "variant": selected,
                    "seed": prompt_seed,
                    "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                    "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
                }
            if original and variant == "sprint":
                system = system.replace("At 240 s", "At 120 s").replace("at 270 s.", "at 150 s.")
                observation["messages"][0]["content"] = system
            if first_system is None:
                first_system = system
            assert system == first_system
            exact.update(json.dumps(observation["messages"], sort_keys=True).encode())
            observation["messages"][0]["content"] = system[system.index("Reply with a single JSON object") :]
            assert view["you"]["alive"]
            roles.add(view["you"]["role"])
            assert not {"seed", "prompt", "policy", "players"} & view.keys()
            record(observation)
            record(request({"kind": "encode"}))
            proposal = request({"kind": "teacher"})
            record(proposal)
            response = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": proposal["response"]}
            )
            assert response["kind"] == "accepted"
            record(response["action"])
            observation = response["observation"]
            decisions += 1
            assert decisions <= 270
        assert observation["kind"] == "terminal" and roles == {"tank", "healer", "dps"}
        assert set(observation["scores"]) == {str(i) for i in range(5)}
        assert len(set(observation["scores"].values())) == 1
        record(observation)
        return digest.hexdigest(), exact.hexdigest()
    finally:
        input_stream.close()
        output_stream.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--baseline-binary", type=Path)
    parser.add_argument("--baseline-root", type=Path)
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
    count = 0
    for variant in ("default", "sprint"):
        for text_mode in (False, True):
            for seed in (17,):
                reference, exact = play(args.binary, manifest, variant, text_mode, "canonical", 0, seed)
                count += 1
                if not text_mode and args.baseline_binary is not None:
                    assert args.baseline_root is not None
                    assert (reference, exact) == play(
                        args.baseline_binary,
                        args.baseline_root / "coworld_manifest_template.json",
                        variant,
                        False,
                        "canonical",
                        0,
                        seed,
                        True,
                    )
                for wording, prompt_seed in [(w, 0) for w in WORDINGS[1:]] + [("mixed", 4)]:
                    actual, _ = play(args.binary, manifest, variant, text_mode, wording, prompt_seed, seed)
                    assert actual == reference
                    count += 1
            print(variant, "text" if text_mode else "numeric", "8 full games PASS", flush=True)
    for wording in WORDINGS[-2:]:
        rejected = subprocess.run(
            [str(args.binary), str(manifest), "default", "text"],
            input=json.dumps({"kind": "reset", "players": 5, "seed": "guard", "promptVariant": wording}) + "\n",
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        assert rejected.returncode != 0 and "held-out wording cannot enter training" in rejected.stderr
    print(count, "complete games and held-out exclusion PASS", flush=True)


if __name__ == "__main__":
    main()
