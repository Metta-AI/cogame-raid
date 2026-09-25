#!/usr/bin/env python3
"""Builds coworld_manifest_template.json.

The manifest inlines the README, docs/RULES.md and docs/PROTOCOL.md as
`game.docs` text, so it is generated rather than hand-maintained: editing a doc
and forgetting the manifest is exactly the drift this removes.

    python3 tools/build_manifest.py

Rewrites coworld_manifest_template.json in place. tests/test_manifest.nim
asserts the invariants (num_agents everywhere, both protocols, non-empty docs).
"""

import json
import os

SEATS = 5
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_URL = "https://github.com/Metta-AI/cogame-raid/tree/main"


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as handle:
        return handle.read()


DESCRIPTION = (
    "Raid: five LLM-piloted cogs against SMELTER-9, a fully scripted foundry "
    "boss. The five seats are dealt one tank, one healer and three damage "
    "roles from the episode seed, so a policy cannot know its role when it is "
    "written and every prompt must cover all three. SMELTER-9 never adapts: it "
    "is bolted to the centre of a 300 px round pit with four sight-blocking "
    "pillars and runs a published, deterministic script of three phases - "
    "Forge, Slag and Meltdown - with a 90-degree telegraphed cleave, slag "
    "pours that leave burning pools, a Crucible Pour whose 240 damage is SPLIT "
    "between the bodies standing in it (nobody in it and the boss keeps a "
    "permanent +20% stack), an interruptible 4-second Overload that heals it "
    "400 if it lands, waves of Slag Crawlers that make it hit 25% harder while "
    "four are alive, and a hard enrage at 240 seconds. Every five seconds each "
    "living seat issues ONE order - an intent, a target, a station and the "
    "reaction it pre-authorises for the next telegraph - and a deterministic "
    "control layer executes it at 24 Hz, so a policy chooses the reaction, not "
    "the dodge. The only channel between seats is a 32-character `say` that "
    "arrives one turn stale. Score is boss health removed divided by time "
    "spent, in units of the enrage timer (1.0 = killed it exactly on the "
    "timer), and every seat carries the identical number, so a healer who "
    "never touches the boss can be a champion. Prompt and Jev policies "
    "receive private seat views through the ordinary player socket and "
    "return complete orders. The game owns timing, order repair, fallback, "
    "results and replay. Stalwart and greenhorn are scripted baselines. "
    "Seats without model credentials fall back to stalwart."
)

CONFIG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        "tokens": {
            "description": "One connection token per player slot, indexed by slot.",
            "type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {"type": "string", "minLength": 1},
        },
        "players": {
            "description": "One player display-name object per seat, indexed by slot.",
            "type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["name"],
                "properties": {"name": {"type": "string", "minLength": 1}},
            },
        },
        "num_agents": {
            "description": "Seat count; injected by the commissioner. Raid is a five-cog encounter.",
            "type": "integer", "minimum": SEATS, "maximum": SEATS,
            "default": SEATS,
        },
        "seed": {
            "description": "Pins the role deal and the pour target draws. Omit for a fresh random seed per episode.",
            "type": "integer",
        },
        "roles": {
            "description": "Optional explicit role deal, exactly five of tank/healer/dps. Omit to deal from the seed.",
            "type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {"type": "string", "enum": ["tank", "healer", "dps"]},
        },
        "turnTicks": {
            "description": "Ticks per decision turn at 24 ticks per second.",
            "type": "integer", "minimum": 24, "maximum": 600, "default": 120,
        },
        "enrageTicks": {
            "description": "Tick at which SMELTER-9 enrages: triple damage, permanent.",
            "type": "integer", "minimum": 240, "maximum": 20000, "default": 5760,
        },
        "maxTicks": {
            "description": "Hard end of the pull. Must be at least enrageTicks.",
            "type": "integer", "minimum": 240, "maximum": 24000, "default": 6480,
        },
        "bossMaxHp": {
            "description": "SMELTER-9's health pool.",
            "type": "integer", "minimum": 100, "maximum": 200000, "default": 26000,
        },
        "turnBudgetSeconds": {
            "description": "Outer per-turn deadline for the whole parallel decision batch.",
            "type": "number", "minimum": 1, "maximum": 60, "default": 10,
        },
        "wallClockBudgetSeconds": {
            "description": "Engine hard stop. Must stay inside 60% of episodeTimeoutSeconds; the budget guard settles the encounter on the scripted layer well before it.",
            "type": "number", "minimum": 30, "maximum": 720, "default": 660,
        },
        "episodeTimeoutSeconds": {
            "description": "Wall clock the game assumes the platform allows when COWORLD_TIMEOUT_SECONDS is not in its environment.",
            "type": "integer", "minimum": 60, "maximum": 6000, "default": 1200,
        },
        "playerConnectTimeoutSeconds": {
            "description": "Bounded wait for the five player containers to connect.",
            "type": "number", "minimum": 0, "maximum": 600, "default": 90,
        },
        "mapPath": {
            "description": "Authored map spec name under data/. Raid ships one floor.",
            "type": "string", "default": "foundry",
        },
        "llmAttemptSeconds": {
            "description": "First-attempt per-seat deadline. llmAttemptSeconds + llmRetrySeconds must be <= turnBudgetSeconds; asserted at config load.",
            "type": "number", "minimum": 1, "maximum": 60, "default": 6.5,
        },
        "llmRetrySeconds": {
            "description": "Deadline for the single retry that carries the invalid-reply hint.",
            "type": "number", "minimum": 1, "maximum": 60, "default": 3.0,
        },
        "showPlayerLabels": {
            "description": "Whether the spectator chrome renders real policy names beside the aliases.",
            "type": "boolean", "default": True,
        },
        "gameOverTicks": {
            "description": "Endcard hold, in ticks, for the broadcast viewer.",
            "type": "integer", "minimum": 0, "maximum": 600, "default": 96,
        },
    },
}

NUM5 = {"type": "array", "minItems": SEATS, "maxItems": SEATS,
        "items": {"type": "integer", "minimum": 0}}
STR5 = {"type": "array", "minItems": SEATS, "maxItems": SEATS,
        "items": {"type": "string"}}

RESULTS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": [
        "names", "aliases", "roles", "policy_kinds", "scores",
        "boss_hp_removed", "boss_max_hp", "boss_hp_removed_frac",
        "elapsed_seconds", "charged_seconds", "enrage_seconds",
        "phase_reached", "kill", "wipe", "deaths", "alive_at_end",
        "damage_to_boss", "damage_to_adds", "healing_done", "overhealing",
        "damage_taken", "avoidable_hits", "interrupts_landed",
        "interrupts_wasted", "overloads_resolved", "adds_killed",
        "spill_stacks", "reason", "end_rule", "final_tick", "final_turn",
        "seed", "llm_turns", "fallback_turns", "fallback_causes",
    ],
    "properties": {
        "names": dict(STR5, description="Policy display names by slot. Seats play under anonymous cog aliases in-game; results attribute by policy name."),
        "aliases": dict(STR5, description="Alpha..Echo, by slot."),
        "roles": dict(STR5, description="The role each seat was dealt: tank, healer or dps."),
        "policy_kinds": dict(STR5, description="llm or scripted, by slot."),
        "scores": {
            "description": "Boss health removed divided by time spent, in units of the enrage timer. Identical for all five seats: shared equally. Higher is better.",
            "type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {"type": "number", "minimum": 0},
        },
        "boss_hp_removed": {"type": "integer", "minimum": 0},
        "boss_max_hp": {"type": "integer", "minimum": 1},
        "boss_hp_removed_frac": {"type": "number", "minimum": 0, "maximum": 1},
        "elapsed_seconds": {"type": "number", "minimum": 0},
        "charged_seconds": {"type": "number", "minimum": 0},
        "enrage_seconds": {"type": "number", "minimum": 0},
        "phase_reached": {"type": "integer", "minimum": 1, "maximum": 3},
        "kill": {"type": "boolean"},
        "wipe": {"type": "boolean"},
        "deaths": {"type": "integer", "minimum": 0},
        "alive_at_end": {"type": "integer", "minimum": 0},
        "damage_to_boss": NUM5,
        "damage_to_adds": NUM5,
        "healing_done": NUM5,
        "overhealing": NUM5,
        "damage_taken": NUM5,
        "avoidable_hits": NUM5,
        "interrupts_landed": NUM5,
        "interrupts_wasted": NUM5,
        "overloads_resolved": {"type": "integer", "minimum": 0},
        "adds_killed": {"type": "integer", "minimum": 0},
        "spill_stacks": {"type": "integer", "minimum": 0, "maximum": 5},
        "reason": {
            "description": "complete, deadline (the hosted LLM was slow; the replay is complete up to the stop tick) or fault.",
            "type": "string", "enum": ["complete", "deadline", "fault"],
        },
        "end_rule": {
            "description": "The detail behind `reason`.",
            "type": "string",
            "enum": ["kill", "wipe", "enrage_timeout", "wall_clock",
                     "sim_fault", "host_error"],
        },
        "final_tick": {"type": "integer", "minimum": 0},
        "final_turn": {"type": "integer", "minimum": 0},
        "seed": {"type": "integer"},
        "llm_turns": NUM5,
        "fallback_turns": NUM5,
        "fallback_causes": {
            "description": "Per seat, how many turns fell back and why.",
            "type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["timeout", "parse_error", "transport_error",
                             "no_credentials", "budget_guard"],
                "properties": {
                    "timeout": {"type": "integer", "minimum": 0},
                    "parse_error": {"type": "integer", "minimum": 0},
                    "transport_error": {"type": "integer", "minimum": 0},
                    "no_credentials": {"type": "integer", "minimum": 0},
                    "budget_guard": {"type": "integer", "minimum": 0},
                },
            },
        },
    },
}

PLAYER_PROTOCOL = (
    "raid.player.v2 - JSON text frames over COWORLD_PLAYER_WS_URL. "
    "player->game: {\"type\":\"register\",\"kind\":\"scripted|prompt|jev\","
    "\"scripted\":\"stalwart|greenhorn|null\",\"policy\":str}; "
    "game->player: {\"type\":\"decision\",\"id\":int,\"slot\":int,"
    "\"view\":object,\"system\":str,\"retry\":bool,"
    "\"timeout_seconds\":int}; player->game: "
    "{\"type\":\"action\",\"id\":int,\"action\":order} or "
    "{\"type\":\"action\",\"id\":int,\"cause\":str,"
    "\"error\":str}. The game sends every living seat's private view "
    "concurrently, validates and repairs orders, and owns bounded retries, "
    "fallback, results and replay. The player owns prompt or Jev inference. "
    "The order has intent, target, station, point, on_telegraph, note and say. "
    "After each turn the game sends an informational turn frame; at the end "
    "it sends {\"done\":true,\"result\":object}. See docs/PROTOCOL.md."
)

GLOBAL_PROTOCOL = (
    "raid.global.v1 - spectators connect a websocket to /global and receive the "
    "whole snapshot as JSON after every decision turn and at the end: "
    "{\"type\":\"state\",\"game\":\"raid\",\"protocol\":\"raid.global.v1\","
    "\"tick\":int,\"turn\":int,\"ticks_per_second\":24,\"phase\":1|2|3,"
    "\"phase_name\":str,\"seats\":[{slot,alias,name,policy_kind,role,pos,aim,"
    "alive,hp,max_hp,shield,mana,threat,attacking,intent,note,say,source,"
    "damage_to_boss,healing_done,damage_taken,avoidable_hits,connected} x5],"
    "\"boss\":{name,pos,aim,hp,max_hp,hp_pct,target,enraged,feed,spill_stacks,"
    "casting,cast_remaining,cast_total},\"adds\":[{id,pos,hp}],"
    "\"pools\":[{id,centre,radius,age}],\"telegraphs\":[{id,kind,centre,radius,"
    "facing_brads,half_angle_brads,reach,fuse,soak_needed}],\"enrage_in_s\":"
    "float,\"hard_end_in_s\":float,\"events\":[...the append-only transcript..."
    "],\"done\":bool,\"reason\":str,\"end_rule\":str,\"score\":float}. Real "
    "policy names appear here, in the replay and in the results - never in a "
    "seat's view. The recorded replay is raid.replay.v1: strict UTF-8 JSON "
    "carrying protocol, format_version, game_version, seed, the fully resolved "
    "config, the map spec inlined verbatim, names (players/aliases/roles/"
    "policy_kinds/colors), ticks_per_second, turn_ticks, tick_count, the phase "
    "table, controls_b64 (tick_count x 5 x 4 bytes of (move_x,move_y,aim_turn,"
    "action)), one keyframe per second with an FNV-1a state digest, the event "
    "transcript and the results. seed + map + config + the recorded order "
    "events reproduce the encounter exactly, which is what the STATIC wasm "
    "replay bundle does in the browser - it contacts nothing but the S3 URL it "
    "was given, and validates itself against the keyframe digests. "
    "/client/replay serves the same page off the identical bundle for local "
    "viewing."
)


def variant(vid, name, description, boss, enrage, max_ticks, wall):
    return {
        "id": vid, "name": name, "description": description,
        "game_config": {
            "players": [{"name": f"Player{i + 1}"} for i in range(SEATS)],
            "num_agents": SEATS,
            "bossMaxHp": boss,
            "turnTicks": 120,
            "enrageTicks": enrage,
            "maxTicks": max_ticks,
            "turnBudgetSeconds": 10,
            "wallClockBudgetSeconds": wall,
            "playerConnectTimeoutSeconds": 90,
            "mapPath": "foundry",
        },
    }


def player_entry(pid, name, description, scripted, jev=False):
    entry = {
        "id": pid, "name": name, "type": "player", "description": description,
        "image": "{{RAID_IMAGE}}", "run": ["/bin/raid-player"],
        "resources": {
            "requests": {"cpu": "100m", "memory": "64Mi"},
            "limits": {"cpu": "1"},
        },
        "source_url": SOURCE_URL,
    }
    if scripted:
        entry["env"] = {"PLAYER_SCRIPTED": scripted}
    if jev:
        entry["env"] = {"PLAYER_JEV": "true"}
    return entry


def build():
    return {
        "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
        "tags": [
            "cooperative", "pve", "boss-encounter", "heterogeneous-roles",
            "ad-hoc-teamwork", "llm-driven", "real-time", "five-player",
        ],
        "episode_timeout_minutes": 20,
        "game": {
            "name": "raid",
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "description": DESCRIPTION,
            "owner": "daveey@softmax.com",
            "runnable": {
                "type": "game",
                "image": "{{RAID_IMAGE}}",
                "run": ["/bin/raid"],
                "source_url": SOURCE_URL,
            },
            "config_schema": CONFIG_SCHEMA,
            "results_schema": RESULTS_SCHEMA,
            "protocols": {
                "player": {"type": "text", "value": PLAYER_PROTOCOL},
                "global": {"type": "text", "value": GLOBAL_PROTOCOL},
            },
            "docs": {
                "readme": {"type": "text", "value": read("README.md")},
                "pages": [
                    {"id": "rules.md", "title": "Rules",
                     "content": {"type": "text",
                                 "value": read("docs", "RULES.md")}},
                    {"id": "protocol.md", "title": "Wire protocol",
                     "content": {"type": "text",
                                 "value": read("docs", "PROTOCOL.md")}},
                ],
            },
        },
        "player": [
            player_entry(
                "baseline", "stalwart",
                "The bundled certification player and the default baseline: "
                "the correct execution of the encounter, played by the server "
                "with no LLM involved.",
                "stalwart"),
            player_entry(
                "greenhorn", "greenhorn",
                "The weaker scripted baseline: everyone in melee, everyone "
                "dodging everything, nobody interrupting, nobody soaking, adds "
                "ignored. A clean floor for the ladder.",
                "greenhorn"),
            player_entry(
                "raid-player", "Raid Prompt Player",
                "The reference prompt policy answers private decision views "
                "with complete orders. Field your own with PLAYER_PROMPT.",
                None),
            player_entry(
                "jev", "Raid Jev Player",
                "Jev selects complete orders from the same private seat view.",
                None, jev=True),
        ],
        "variants": [
            variant("default", "SMELTER-9 (5 cogs, 240 s enrage)",
                    "The full pull: 26000 boss health, enrage at 240 s, hard "
                    "stop at 270 s, up to 54 decision turns.",
                    26000, 5760, 6480, 660),
            variant("sprint", "SMELTER-9 Sprint (5 cogs, 120 s enrage)",
                    "Cheap ladder rounds: half the health pool and half the "
                    "enrage timer together, so the score scale is unchanged "
                    "and a kill on the timer is still 1.0. Never changes the "
                    "seat count.",
                    13000, 2880, 3600, 400),
        ],
        "certification": {
            "game_config": {
                "players": [{"name": f"P{i + 1}"} for i in range(SEATS)],
                "num_agents": SEATS,
                "seed": 42,
                "roles": ["tank", "healer", "dps", "dps", "dps"],
                "bossMaxHp": 3000,
                "turnTicks": 120,
                "enrageTicks": 960,
                "maxTicks": 1200,
                "turnBudgetSeconds": 10,
                "wallClockBudgetSeconds": 180,
                "playerConnectTimeoutSeconds": 60,
                "mapPath": "foundry",
            },
            "players": [
                # Certification's players-run step requires every declared
                # player entry to occupy a slot. Tank and healer stay on the
                # strong baseline so the fixture still reaches a kill.
                {"player_id": "baseline"},
                {"player_id": "baseline"},
                {"player_id": "greenhorn"},
                {"player_id": "raid-player"},
                {"player_id": "jev"},
            ],
        },
    }


if __name__ == "__main__":
    path = os.path.join(ROOT, "coworld_manifest_template.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(build(), handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("wrote", path)
