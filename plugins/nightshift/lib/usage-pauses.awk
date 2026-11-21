# The not-work inside one span, by the reason each pause was recorded under.
#
# Two files: the usage marks (`<epoch>\t<label>\t...`), then pauses.tsv (`<epoch>\t<reason>`).
# Only a pause at or after -v from and before -v to counts. Lines that share one epoch are one
# pause, and the first line gives the reason. A counted pause ends at the earliest of the first
# mark after it, the next later pause epoch anywhere in pauses.tsv, and to. A pause no mark
# followed is still open and is left out rather than guessed at. That is the gap
# ns_usage_paused_between measures, so the lines here sum to its total.
#
# Prints: <reason>\t<seconds> per reason, in the order each reason was first recorded. A reason
# whose total is 0 is left out.

BEGIN { FS = "\t" }

FILENAME == ARGV[1] {
  if ($1 ~ /^[0-9]+$/) mark[++marks] = $1 + 0
  next
}

$1 ~ /^[0-9]+$/ {
  at = $1 + 0
  if (at in seen) next
  seen[at] = 1
  pause_at[++pauses] = at
  pause_why[pauses] = (NF >= 2 && $2 != "") ? $2 : "paused"
  next
}

END {
  for (p = 1; p <= pauses; p++) {
    at = pause_at[p]
    if (at < from || at >= to) continue
    resumed = -1
    for (i = 1; i <= marks; i++) {
      if (mark[i] > at) {
        resumed = mark[i]
        break
      }
    }
    if (resumed < 0) continue
    next_pause = -1
    for (q = 1; q <= pauses; q++) {
      if (pause_at[q] > at && (next_pause < 0 || pause_at[q] < next_pause))
        next_pause = pause_at[q]
    }
    end = resumed
    if (next_pause >= 0 && next_pause < end) end = next_pause
    if (end > to) end = to
    why = pause_why[p]
    if (!(why in total)) order[++reasons] = why
    total[why] += end - at
  }
  for (i = 1; i <= reasons; i++)
    if (total[order[i]] > 0) printf "%s\t%d\n", order[i], total[order[i]]
}
