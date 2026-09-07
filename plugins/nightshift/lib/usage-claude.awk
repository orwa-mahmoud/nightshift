# One cumulative usage reading from a Claude Code session transcript.
#
# A bounded scan, not a JSON parser: each number is read from the one line that carries it, the
# same way the rules reader works. It never has to understand the document, only find five fields
# on a line that already announced it has usage.
#
# The deduplication is the whole point. One API response is written as several lines, one per
# content block, and every one repeats the same usage object. Summing lines instead of responses
# inflates the total — 2,421 usage-bearing lines for 1,526 responses on a real session — and the
# ratio moves with how many blocks a response happens to have, so this deduplicates on identity
# rather than dividing by a constant. Identity is requestId, falling back to the message id.
#
#   -v size=<bytes>   the offset this read finishes at, echoed back for the caller to persist
#   -v carry=<id>     the last identity the previous read counted, so a response whose lines
#                     straddle the boundary is not counted a second time
#   stdin             the appended bytes since the last read
#
# A line that does not end in a closing brace was still being written; it is skipped entirely
# rather than half-read, and the next read picks it up whole.
#
# Deduplication has to survive the read boundary as well as the read. One response is several
# lines; a read that ends between them leaves the rest to be picked up next time, still carrying
# the same identity. Counting it again would bill that response twice. The caller persists the last
# identity counted and hands it back as `carry`, and the lines that repeat it are skipped until a
# different identity appears.
#
# Prints: <fields>\t<offset>\t<model>\t<responses>\t<last-identity>

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
  if (index($0, "\"usage\"") == 0) next
  # A line the host had not finished writing when this ran. Its numbers may be cut mid-digit, so
  # nothing is taken from it: a partial figure presented as a complete one is worse than waiting
  # for the next read, which will see the whole line.
  if (substr($0, length($0)) != "}") next
  id = str($0, "requestId")
  if (id == "") id = str($0, "id")
  if (id == "") next
  # The response the previous read was in the middle of. Skipped until the identity changes;
  # once it has, the carry is spent and a later line that repeats it is a genuine repeat.
  if (carry != "" && id == carry && !changed) next
  if (id != carry) changed = 1
  if (id in seen) next
  seen[id] = 1
  last = id
  responses++
  m = str($0, "model")
  if (m != "") model = m
  v = num($0, "input_tokens");                if (v >= 0) input += v
  v = num($0, "cache_creation_input_tokens"); if (v >= 0) cachew += v
  v = num($0, "cache_read_input_tokens");     if (v >= 0) cacher += v
  v = num($0, "output_tokens");               if (v >= 0) output += v
  v = num($0, "thinking_tokens");             if (v >= 0) reason += v
}

END {
  printf "input=%d,cache_write=%d,cache_read=%d,output=%d,reasoning=%d\t%s\t%s\t%d\t%s", \
    input + 0, cachew + 0, cacher + 0, output + 0, reason + 0, size, model, responses + 0, \
    (last != "" ? last : carry)
}
