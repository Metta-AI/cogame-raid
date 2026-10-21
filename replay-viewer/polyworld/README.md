# Optional Raid presentation experiment

This viewer draws detached public frames from the existing Raid replay simulator.
It does not change the hosted viewer, simulation, player protocol, or replay format.
The hosted viewer remains the default: this experiment lacks its replay URL and
parent-frame integration, playback speed control, and full combat display.

Build with Nim 2.2.4 and an installed Emscripten compiler. The current qualification
used Emscripten 3.1.69. Keep dependencies isolated from shared package caches:

- Polyworld: `449ad184052567c30fa54c269ef45ff8c9e8e29b`.
- Raid packages: exact revisions in `nimby.lock`, each extracted under
  `DEPENDENCIES/NAME-REVISION`.
- Shady override: `c899f7cd17dbe7021d6e3aa2908e6de6549c47f1`, required by
  this Polyworld WebGL backend, in the same directory layout.

```sh
./tools/build_raid_polyworld.sh /path/to/polyworld /path/to/dependencies /path/to/output
nim r --path:src tools/raid_public_replay.nim /path/to/replay.json /path/to/output/encounter.public.json /path/to/private-oracle.json
python3 -m http.server 8000 --bind 127.0.0.1 --directory /path/to/output
```

Open `http://127.0.0.1:8000`. Play, pause, seek, restart and resize operate on
public presentation copies. The exporter removes private player data; do not
serve an unfiltered replay or private capture directory.

`tools/record_terminal_coverage.nim OUTPUT` retains complete native fixtures,
public replay exports and authoritative terminal summaries for seeds 42, 7 and
123. These terminate through wipes; they do not establish kill-path coverage.
The browser's `raidReplay.inspect(index)` can be compared with the native oracle
without modifying replay state. Keep historical evidence tied to its source pin.
