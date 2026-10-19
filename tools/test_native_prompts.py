"""Run a published five-player game through real HTTP, players, and replay output."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("revision")
    parser.add_argument("--variant", default="default")
    parser.add_argument("--wording", default="canonical")
    parser.add_argument("--mode", choices=("accepted", "retry", "fallback"), default="accepted")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip() == args.revision
    assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    configs = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    config = dict(configs[args.variant])
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=4,
        tokens=[f"t{i}" for i in range(5)],
        players=[{"name": f"policy-{i}"} for i in range(5)],
    )
    work = args.output.resolve()
    work.mkdir(parents=True, exist_ok=False, mode=0o700)
    (work / "config.json").write_text(json.dumps(config))
    (work / "tmp").mkdir(mode=0o700)
    requests = []
    counts = {}
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, format, *arguments):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seat = int(self.path.split("/")[1])
            user = body["messages"][0]["content"]
            view, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
            key = (view["tick"], seat)
            with lock:
                counts[key] = counts.get(key, 0) + 1
                attempt = counts[key]
                call_id = str(uuid5(NAMESPACE_URL, f"raid-{view['tick']}-{seat}-{attempt}"))
            proposal = {"intent": "wait", "note": "fixture", "say": "fixture"}
            status = 429 if args.mode == "fallback" else 200
            response = {"content": [{"type": "text", "text": json.dumps(proposal)}], "stop_reason": "end_turn"}
            if args.mode == "retry" and attempt == 1:
                response["content"][0]["text"] = "not a directive"
            if status == 429:
                response = {"error": {"type": "rate_limit_error", "message": "fixture throttle"}}
            raw = json.dumps(response).encode()
            with lock:
                requests.append(
                    {"call_id": call_id, "seat": seat, "body": body, "status": status, "raw": raw.decode(), "key": key}
                )
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("X-Coworld-Call-Id", call_id)
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    port = free_port()
    env = os.environ.copy()
    for name in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "PLAYER_SCRIPTED",
    ):
        env.pop(name, None)
    env.update(
        TMPDIR=str(work / "tmp"),
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(work / "config.json").as_uri(),
        COGAME_RESULTS_URI=(work / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
        RAID_HOST_TRACE_PATH=str(work / "host.jsonl"),
        RAID_ATTEMPT_TRACE_DIR=str(work / "attempts"),
        RAID_SOURCE_REVISION=args.revision,
    )
    processes, logs = [], []
    try:
        log = (work / "game.log").open("w")
        logs.append(log)
        game = subprocess.Popen([str(args.game.resolve())], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append(game)
        for _ in range(400):
            assert game.poll() is None
            with socket.socket() as probe:
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
            if ready:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("host did not start")
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz") as health:
            assert health.status == 200
            (work / "health.txt").write_bytes(health.read())
        for seat in range(5):
            player_env = dict(
                env,
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{provider.server_port}/{seat}",
                PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Fight the boss.",
            )
            log = (work / f"player-{seat}.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen(
                    [str(args.player.resolve())], cwd=root, env=player_env, stdout=log, stderr=subprocess.STDOUT
                )
            )
        assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
        for player in processes[1:]:
            assert player.wait(timeout=20) == 0
        results = json.loads((work / "results.json").read_text())
        assert results["reason"] == "complete" and len(results["scores"]) == 5
        records = [json.loads(line) for line in (work / "host.jsonl").read_text().splitlines()]
        assert records[0]["source_revision"] == args.revision
        assert records[-1]["event_type"] == "episode_finished" and records[-1]["results"] == results
        decisions = [row for row in records if row["event_type"] == "host_decision"]
        assert 0 < len(decisions) <= 270
        assert len(set(results["scores"])) == 1
        starts, finishes = {}, {}
        received = {row["call_id"]: row for row in requests}
        for path in (work / "attempts").glob("*.jsonl"):
            assert path.stat().st_mode & 0o777 == 0o600
            start, finish = [json.loads(line) for line in path.read_text().splitlines()]
            identity = start["attempt_id"]
            assert identity == finish["attempt_id"]
            starts[identity], finishes[identity] = start, finish
            headers = {key.lower(): value for key, value in finish["response_headers"].items()}
            actual = received[headers["x-coworld-call-id"]]
            assert actual["body"] == start["request"]["body"]
            assert actual["raw"] == finish["raw_response"] and actual["status"] == finish["http_status"]
            assert actual["seat"] == start["seat"] and start["source_revision"] == args.revision
            for message in start["prompt"]:
                assert (
                    start["prompt_configuration"][message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            system, user = [message["content"] for message in start["prompt"]]
            assert system == actual["body"]["system"] and actual["body"]["messages"] == start["prompt"][1:]
            assert "policy-" not in user
            for seat in range(5):
                assert (f"PRIVATE-STRATEGY-{seat}:" in user) == (seat == start["seat"])
        assert len(starts) == len(requests)
        outcomes = {row["attempt_id"]: row for row in records if row["event_type"] == "host_attempt"}
        assert set(outcomes) == set(starts)
        assert len(starts) == len(decisions) * (1 if args.mode == "accepted" else 2)
        identifiers = set()
        for row in decisions:
            assert row["prompt_configuration"]["variant"] == ("reordered" if args.wording == "mixed" else args.wording)
            assert row["observation"]["you"]["alive"]
            for attempt in range(row["attempts"]):
                identity = f"{row['tick']}-{row['seat']}-{attempt}"
                start = starts[identity]
                assert start["seat"] == row["seat"]
                key = (start["seat"], start["decision_id"])
                assert key not in identifiers
                identifiers.add(key)
                user = start["prompt"][1]["content"]
                view, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
                assert view == row["observation"]
                assert outcomes[identity]["reply"] == finishes[identity]["player_reply"]
            if args.mode == "fallback":
                assert row["source"] == "fallback" and row["selected_attempt_id"] is None
                assert row["failure"] == "transport_error"
            else:
                chosen = row["selected_attempt_id"]
                assert row["source"] == "llm" and outcomes[chosen]["accepted"]
                assert row["executed_action"] == outcomes[chosen]["parsed_action"]
                if args.mode == "retry":
                    first = f"{row['tick']}-{row['seat']}-0"
                    assert not outcomes[first]["accepted"] and outcomes[first]["failure"] == "parse_error"
        replay = json.loads((work / "episode.replay").read_text())
        assert replay["results"] == results
        orders = {(row["turn"], row["seat"]): row for row in replay["events"] if row["type"] == "order"}
        for row in decisions:
            recorded = orders[(row["turn"], row["seat"])]
            for key in ("intent", "target", "station", "on_telegraph", "note", "say"):
                assert recorded[key] == row["executed_action"][key]
        assert b"PRIVATE-STRATEGY-" not in (work / "episode.replay").read_bytes()
        assert "PRIVATE-STRATEGY-" not in (work / "host.jsonl").read_text()
        assert "PRIVATE-STRATEGY-" not in (work / "results.json").read_text()
        assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
        (work / "proof.json").write_text(
            json.dumps(
                {
                    "source_revision": args.revision,
                    "variant": args.variant,
                    "wording": args.wording,
                    "mode": args.mode,
                    "decisions": len(decisions),
                    "http_requests": len(requests),
                    "scores": results["scores"],
                }
            )
        )
        print(work.name, len(decisions), "decisions;", len(requests), "actual HTTP requests; PASS", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        for log in logs:
            log.close()
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=10)


if __name__ == "__main__":
    main()
