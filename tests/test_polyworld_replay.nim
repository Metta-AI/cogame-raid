import std/[json, strutils]
import support/helpers
import raid/polyworld_replay

var world = runScripted(certConfig(), skStalwart)
var document = replayJson(world, resultsJson(world))
document["coach_training"] = %"PRIVATE-COACH-TRANSCRIPT"
document["config"]["prompt"] = %"PRIVATE-PROMPT"
document["names"]["players"] = %*["PRIVATE-POLICY", "Bravo", "Charlie", "Delta", "Echo"]
document["results"]["names"] = %*["PRIVATE-POLICY", "Bravo", "Charlie", "Delta", "Echo"]
for record in document["events"]:
  if record["type"].getStr() == "order": record["note"] = %"PRIVATE-NOTE"
let publicDocument = publicReplay(document)
check("PRIVATE-" notin $publicDocument, "public resource contains no private markers")
checkEq(publicDocument["controls_b64"], document["controls_b64"], "canonical controls unchanged")
checkEq(publicDocument["keyframes"], document["keyframes"], "checkpoints unchanged")
let original = loadPresentationReplay(document)
let exported = loadPresentationReplay(publicDocument)
checkEq(original.scenes, exported.scenes, "every public scene matches private reconstruction")
checkEq(original.digests, exported.digests, "every public digest matches")
checkEq(original.summary, exported.summary, "score and terminal tick match")
var broken = parseJson($publicDocument)
broken["controls_b64"] = %"AA=="
var rejected = false
try: discard loadPresentationReplay(broken)
except RaidError: rejected = true
check(rejected, "corrupted canonical controls rejected")
echo "test_polyworld_replay: public resource, scene parity and control rejection hold"
