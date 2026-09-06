# One usage reading from a Cursor stop payload.
#
# Cursor puts the figures on the payload itself — there is no transcript carrying them, and the
# local agent transcripts have none. The fields are optional and were undocumented when this was
# written, so every one is read defensively: a payload without them prints nothing, and the caller
# reports unavailable rather than treating silence as zero.
#
# Cursor's input overlaps its cache figures, and it reports neither reasoning nor subagent tokens.
#
# Prints: <fields>\t0\t<model>\t0

function num(line, key,   pos, rest, out, ch, i) {
  pos = index(line, "\"" key "\":")
  if (pos == 0) return -1
  rest = substr(line, pos + length(key) + 3)
  out = ""
  for (i = 1; i <= length(rest); i++) {
    ch = substr(rest, i, 1)
    if (ch ~ /[0-9]/) { out = out ch; continue }
    break
  }
  if (out == "") return -1
  return out + 0
}

function str(line, key,   pos, rest, stop) {
  pos = index(line, "\"" key "\":\"")
  if (pos == 0) return ""
  rest = substr(line, pos + length(key) + 4)
  stop = index(rest, "\"")
  if (stop == 0) return ""
  return substr(rest, 1, stop - 1)
}

{
  input = num($0, "input_tokens")
  output = num($0, "output_tokens")
  if (input < 0 && output < 0) next
  cacher = num($0, "cache_read_tokens")
  cachew = num($0, "cache_write_tokens")
  model = str($0, "model")
  found = 1
}

END {
  if (!found) exit 1
  first = 1
  if (input >= 0) { printf "input=%d", input; first = 0 }
  if (cachew >= 0) { if (!first) printf ","; printf "cache_write=%d", cachew; first = 0 }
  if (cacher >= 0) { if (!first) printf ","; printf "cache_read=%d", cacher; first = 0 }
  if (output >= 0) { if (!first) printf ","; printf "output=%d", output }
  printf "\t0\t%s\t0", model
}
