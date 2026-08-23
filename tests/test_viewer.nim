## The viewer smoke: static assertions over the chrome and the shell, plus the
## node harness against the emitted wasm module when a bundle is present.
##
## The wasm half only runs where replay-viewer/dist exists (the wasm-viewer CI
## job, or a local build); the static half runs everywhere, because the chrome
## ids and the coworld-replay bridge are what the platform's viewer route and
## SPEC check 8(c) depend on.

import std/[json, os, osproc, strutils]
import support/helpers

const InheritedChromeIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
  "ffwd-mini", "mmwarn", "bannerlane",
  "killfeed", "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd",
  "btn-end", "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
  "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
  "scrub-win", "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
  "ec-teams", "ec-replay", "status", "lockerroom", "lk-art", "lk-bg",
  "lk-sprites", "lk-cap"
]

const AddedRaidIds = [
  "bossbar", "bossbar-fill", "phasetick-70", "phasetick-35", "bossbar-label",
  "castbar", "enrageclock", "nameplates", "soakpip", "buffrow", "meters",
  "ev-lane", "ev-tip"
]

## The board is not pannable in raid (one fixed arena), so the starter's zoom
## bar + minimap panel is dropped rather than hidden.
const RemovedZoomIds = [
  "viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
  "zoom-slider", "zoom-in", "zoom-read"
]

const RemovedCtfIds = [
  "fpv", "fpv-canvas", "fpv-hud", "fpv-hp", "fpv-map", "fpv-map-canvas",
  "fpv-name", "fpv-cap", "fpv-gear", "fpv-grip", "povBadge"
]

proc testChromeMarkup() =
  let page = repoFile("client/replay_broadcast.html")
  for id in InheritedChromeIds:
    check("id=\"" & id & "\"" in page,
      "the inherited chrome id #" & id & " is still there")
  for id in AddedRaidIds:
    check("id=\"" & id & "\"" in page, "raid's #" & id & " exists")
  for id in RemovedCtfIds:
    check("id=\"" & id & "\"" notin page,
      "the CTF-only #" & id & " is gone")
  for id in RemovedZoomIds:
    check("id=\"" & id & "\"" notin page, "the zoom/minimap #" & id & " is gone")
  check("core.attachMinimap" notin page and "core.zoomAt" notin page,
    "and nothing wires the zoom API")
  ## The event lane: markers are real buttons that seek on click, placed on
  ## the scrubber's tick axis, and the transport band is reserved so the
  ## nameplates sit above the scrubber instead of over it.
  check("mark.onclick" in page and "core.seek(record.t)" in page,
    "event markers seek on click")
  check("document.createElement('button')" in page, "and are buttons")
  check("root.style.setProperty('--band'" in page, "relayout reserves the transport band on :root")
  check("#endcard.on { display: flex" in page and "classList.add('on')" in page,
    "the endcard is shown with the class its CSS rule uses")
  check("$('endcard').classList.remove('on')" in page and "rawSeek(tick)" in page,
    "and every seek takes the endcard down again")
  check("bottom: var(--band, 0px);" in page,
    "the endcard stops above the transport band")
  check("bottom: calc(var(--band, 0px) + 4 * var(--u))" in page,
    "and the nameplates ride above it")
  ## The inherited relayout loop and its two knobs.
  check("--hudscale" in page, "the --hudscale relayout knob is inherited")
  check("classList.toggle('tiny'" in page, "and the .tiny class at 620 px")
  done("the chrome markup: inherited ids kept, raid ids added, CTF ids gone")

proc testLegibleAt360() =
  let page = repoFile("client/replay_broadcast.html")
  check(".plate-name { flex: 1 1 auto; min-width: 3.2em" in page,
    "the .plate-name rule that stops policy names collapsing to an ellipsis")
  check("@media (max-width: 640px)" in page,
    "and the 640 px media block that protects the boss bar, the hp bars and " &
    "the enrage clock")
  ## The three things that must read at 360 px are inside that block.
  let block360 = page[page.find("@media (max-width: 640px)") .. ^1]
  for needle in ["#nameplates", "#bossbar"]:
    check(needle in block360[0 ..< min(2200, block360.len)],
      needle & " is handled by the 640 px rules")
  check("clamp(13px, 4.2vw, 26px)" in page,
    "and the endcard headline scales with the viewport")
  done("the scorebug stays legible at 360 px")

proc testCoworldReplayBridge() =
  let shell = repoFile("replay-viewer/static_replay.js")
  check("coworld-replay" in shell, "the coworld-replay postMessage bridge")
  check("tell(\"loading\")" in shell or "tell('loading')" in shell,
    "reports loading on script entry")
  check("tell(\"ready\")" in shell or "tell('ready')" in shell,
    "reports READY after the first drawn frame")
  check("tell('error'" in shell or "tell(\"error\"" in shell,
    "and reports error when the replay cannot be shown")
  check("requestAnimationFrame" in shell,
    "with the double rAF so ready means a picture")
  check("data-replay-loaded" in shell, "sets data-replay-loaded")
  check("data-replay-mismatch-tick" in shell,
    "and surfaces a digest mismatch as an attribute")
  check("FETCH_TIMEOUT_MS" in shell, "bounds the fetch")
  check("static_replay_worker.js" in shell,
    "and owns the wasm runtime in a Worker")
  let worker = repoFile("replay-viewer/static_replay_worker.js")
  check("raid_load_replay" in worker, "the worker loads the replay")
  check("raid_mismatch_tick" in worker, "and reads the digest mismatch back")
  done("the coworld-replay bridge, including tell(\"ready\")")

proc testWireConstantsAreShared() =
  let generator = repoFile("tools/gen_wire_constants.nim")
  check("window.RAID_WIRE=" in generator,
    "wire constants are published to the browser")
  for needle in ["TargetFps", "PitRadius", "CleaveReach", "roleColors"]:
    check(needle in generator,
      "and carry " & needle & " so the chrome cannot drift from the sim")
  done("the wire constants are generated from the sim's own constants")

proc testBundleRecipeIsComplete() =
  let dockerfile = repoFile("Dockerfile.replay-viewer")
  for asset in ["raid_replay.wasm", "raid_replay.js", "raid_replay.data",
      "index.html", "static_replay.js", "static_replay_worker.js",
      "chrome_common.js", "broadcast_core.js", "wire_constants.js",
      "font.ttf", "art/floor_foundry.jpg", "art/boss_smelter.png",
      "art/add_crawler.png", "art/cog_tank.png", "art/cog_healer.png",
      "art/cog_dps.png", "art/pool.png", "art/telegraph_ring.png",
      "art/pillar.png"]:
    check(asset in dockerfile, "the bundle ships " & asset)
  check("grep -q 'coworld-replay'" in dockerfile,
    "and the build asserts the bridge survived into dist")
  let hook = repoFile("tools/build_replay_viewer.sh")
  check("static-replay-viewer" in hook, "the hook guards its output name")
  check("Dockerfile.replay-viewer" in hook,
    "and falls back to the pinned emsdk container")
  done("the bundle recipe lists every file the platform serves")

proc testArtIsReal() =
  for asset in ["floor_foundry.jpg", "boss_smelter.png", "add_crawler.png",
      "cog_tank.png", "cog_healer.png", "cog_dps.png", "pool.png",
      "telegraph_ring.png", "pillar.png"]:
    let bytes = repoFile("client/art/" & asset)
    check(bytes.len > 300,
      "client/art/" & asset & " is real art, not a placeholder (" &
      $bytes.len & " bytes)")
  check(repoFile("data/font.ttf").len > 1000, "and the font ships")
  done("the board art is present and non-trivial")

proc distDir(): string =
  for candidate in ["replay-viewer/dist", "../replay-viewer/dist"]:
    if dirExists(candidate):
      return candidate
  ""

proc testWasmHarness() =
  ## Only where a bundle exists. Loads the EXACT emitted module under node
  ## with a recorded replay, advances to the end, and asserts the tick total,
  ## the final digest and that seeking lands exactly.
  let dist = distDir()
  if dist.len == 0 or not fileExists(dist / "raid_replay.js"):
    echo "skip: no replay-viewer/dist bundle in this checkout"
    return
  if findExe("node").len == 0:
    echo "skip: node is not on PATH"
    return
  let world = runScripted(certConfig(), skStalwart)
  let replayPath = getTempDir() / "raid-wasm-smoke.json"
  writeFile(replayPath, replayBytes(world))
  let harness = "tools/wasm_replay_smoke.cjs"
  check(fileExists(harness), "the node harness is committed")
  let output = execProcess("node", args = [harness, dist / "raid_replay.js",
    replayPath, $world.tick], options = {poUsePath, poStdErrToStdOut})
  echo output
  check("WASM-SMOKE OK" in output, "the wasm module replays the encounter")
  removeFile(replayPath)
  done("the wasm module replays a recorded encounter under node")

when isMainModule:
  testChromeMarkup()
  testLegibleAt360()
  testCoworldReplayBridge()
  testWireConstantsAreShared()
  testBundleRecipeIsComplete()
  testArtIsReal()
  testWasmHarness()
  echo "test_viewer: the viewer chrome, the bridge and the bundle check out"
