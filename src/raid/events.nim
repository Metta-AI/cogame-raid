## The replay event vocabulary. Every record is a JSON object carrying `t`
## (the tick) plus its own fields; the writer keeps them in emission order and
## the viewer's feed reads them straight through.

import std/[json]

type
  EventBuffer* = object
    records*: seq[JsonNode]

proc emit*(buffer: var EventBuffer, tick: int, kind: string,
    fields: JsonNode) =
  var record = %*{"t": tick, "type": kind}
  if fields != nil and fields.kind == JObject:
    for key, value in fields.pairs:
      record[key] = value
  buffer.records.add(record)

proc toJson*(buffer: EventBuffer): JsonNode =
  result = newJArray()
  for record in buffer.records:
    result.add(record)

proc countOf*(buffer: EventBuffer, kind: string): int =
  for record in buffer.records:
    if record{"type"}.getStr() == kind:
      result.inc

proc lastOf*(buffer: EventBuffer, kind: string): JsonNode =
  for i in countdown(buffer.records.high, 0):
    if buffer.records[i]{"type"}.getStr() == kind:
      return buffer.records[i]
  nil
