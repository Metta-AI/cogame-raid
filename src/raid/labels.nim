## Names and text safety.
##
## Two name spaces: `Alpha` .. `Echo` are the only names a prompt or an
## observation ever contains; the real policy names live in the replay's
## `names.players`, the results and the viewer chrome.
##
## Every string that can reach the replay, the results, or another seat's
## callouts goes through `runeCap` first. Truncation is on RUNE boundaries,
## never bytes: a byte-truncated multi-byte character renders in a browser and
## then fails a strict JSON parser, which is exactly the bug that makes a
## hosted replay unreadable.

import std/[strutils, unicode]
import types

proc aliasOf*(slot: int): string =
  if slot < 0 or slot >= Aliases.len:
    return "?"
  Aliases[slot]

proc slotOfAlias*(name: string): int =
  let wanted = name.strip().toLowerAscii()
  for slot, alias in Aliases:
    if alias.toLowerAscii() == wanted:
      return slot
  -1

proc addName*(id: int): string =
  "A" & $id

proc runeCap*(text: string, limit: int): string =
  ## Trims to `limit` runes. Newlines become spaces so one callout cannot
  ## break a log line or a feed row.
  var cleaned = text.replace("\r", " ").replace("\n", " ").strip()
  if cleaned.runeLen <= limit:
    return cleaned
  cleaned.runeSubStr(0, limit)

proc sanitizeName*(text: string, limit: int): string =
  let capped = runeCap(text, limit)
  if capped.len == 0: "policy" else: capped
