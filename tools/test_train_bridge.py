"""Play both certified Raid variants through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool, seed: str | None = None) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": seed or f"raid-{variant}-{teacher}", "players": 5})
        widths = set()
        decisions = 0
        saw_late_add = False
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [14, 15, 6, 1236, 660, 2, 4]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            saw_late_add |= any(int(add["id"][1:]) > 8 for add in view["adds"])
            assert "seed" not in view and "your_last_order" in view
            assert "name" not in view["you"] and len(view["raid"]) == 5
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 300
        assert observation["kind"] == "terminal"
        scores = observation["scores"]
        utilities = observation["utilities"]
        assert set(scores) == {str(i) for i in range(5)}
        assert len(set(scores.values())) == 1
        assert len(set(utilities.values())) == 1
        assert -1 <= utilities["0"] <= 1
        assert widths == {292}
        if seed == "0":
            assert saw_late_add
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    next_views = []
    for intent in ("wait", "soak"):
        process = subprocess.Popen(
            [str(binary), str(manifest), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "raid-simultaneous", "players": 5})
        action = {"intent": intent, "target": 1, "station": "ranged",
                  "point_x": 617, "point_y": 329, "has_point": False,
                  "on_telegraph": "dodge"}
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps(action)}
        )["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)
    play(binary, "default", True, seed="0")
