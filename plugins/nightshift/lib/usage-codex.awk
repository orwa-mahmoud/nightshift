# One cumulative usage reading from a Codex rollout's last `token_count` line.
#
# The overlap is Codex's own and is carried through rather than corrected: cached_input_tokens is
# inside input_tokens, reasoning_output_tokens is inside output_tokens. The report states that
# once so nothing is counted twice downstream.
#
# The format is documented as not stable for hooks, so a line missing total_token_usage prints
# nothing at all — the caller then reports unavailable with the reason, rather than a partial sum
# dressed as a complete one.
#
# Prints: <fields>\t<offset>\t<model>\t<responses>   (offset and responses are 0: the counter is
# already cumulative, so there is nothing to page through and nothing to deduplicate.)

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
  if (index($0, "\"total_token_usage\"") == 0) next
  block = substr($0, index($0, "\"total_token_usage\""))
  input = num(block, "input_tokens")
  output = num(block, "output_tokens")
  if (input < 0 || output < 0) next
  cacher = num(block, "cached_input_tokens")
  cachew = num(block, "cache_write_input_tokens")
  reason = num(block, "reasoning_output_tokens")
  model = str($0, "model")
  found = 1
}

END {
  if (!found) exit 1
  printf "input=%d", input
  if (cachew >= 0) printf ",cache_write=%d", cachew
  if (cacher >= 0) printf ",cache_read=%d", cacher
  printf ",output=%d", output
  if (reason >= 0) printf ",reasoning=%d", reason
  printf "\t0\t%s\t0", model
}
