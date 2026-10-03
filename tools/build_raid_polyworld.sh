#!/usr/bin/env bash
# Optional local experiment, never changes the hosted replay bundle.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" != 3 ]]; then
  printf 'usage: %s PINNED_POLYWORLD PINNED_DEPENDENCY_ROOT PRIVATE_OUTPUT\n' "$0" >&2
  exit 2
fi
polyworld="$(realpath "$1")"
dependencies="$(realpath "$2")"
output="$(realpath -m "$3")"
# This experiment is bound to Polyworld 449ad184052567c30fa54c269ef45ff8c9e8e29b.
printf '%s  %s\n' c5a77d9b0b7f58ffefdf9fe73b2423ec9ea8f3cc29fbab150b0c0d021a9d98a0 \
  "$polyworld/src/polyworld/shapes.nim" | sha256sum -c -
mkdir -p "$output"
paths=("--path:$root/src" "--path:$polyworld/src")
for package in "${NIMBY_PACKAGES:-$HOME/.nimby/pkgs}"/* "$dependencies"/*; do
  [[ -d "$package" ]] || continue
  if [[ -d "$package/src" ]]; then paths+=("--path:$package/src")
  else paths+=("--path:$package"); fi
done
cd "$root"
RAID_BROWSER_OUTPUT="$output" EMCC_CORES=1 nim c --skipParentCfg:on \
  --skipUserCfg:on --hints:off "${paths[@]}" replay-viewer/polyworld/raid_polyworld.nim
cp replay-viewer/polyworld/index.html replay-viewer/polyworld/replay.js "$output/"
printf 'Build complete. Export a public replay as %s/encounter.public.json before serving locally.\n' "$output"
