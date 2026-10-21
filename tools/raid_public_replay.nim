## Export only public reconstruction inputs and native presentation oracle.
import std/[json, os]
import raid/polyworld_replay

if paramCount() != 3:
  quit("usage: raid_public_replay INPUT PUBLIC_REPLAY PRIVATE_ORACLE", 2)
let document = parseFile(paramStr(1))
let runtime = loadPresentationReplay(document)
let publicDocument = publicReplay(document)
writeFile(paramStr(2), $publicDocument)
var frames = newJArray()
for index in 0 ..< runtime.scenes.len: frames.add(runtime.frameJson(index))
writeFile(paramStr(3), $ %*{"frames": frames, "summary": runtime.summary})
echo "PUBLIC-REPLAY OK: ", runtime.scenes.len, " native frames, ", runtime.summary
