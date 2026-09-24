# The not-work inside one span, by the reason each pause was recorded under.
#
# Two files: the usage marks (`<epoch>\t<label>\t...`), then pauses.tsv (`<epoch>\t<reason>`). A
# pause at or after -v from and before -v to lasts until the first mark written after it, never
# past to; a pause no mark followed is still open and is left out rather than guessed at. That is
# the gap ns_usage_paused_between measures, so the lines here sum to its total.
#
# Prints: <reason>\t<seconds> per reason, in the order each reason was first recorded.

BEGIN { FS = "\t" }

FILENAME == ARGV[1] {
  if ($1 ~ /^[0-9]+$/) mark[++marks] = $1 + 0
  next
}

$1 ~ /^[0-9]+$/ {
  at = $1 + 0
  if (at < from || at >= to) next
  resumed = -1
  for (i = 1; i <= marks; i++) {
    if (mark[i] > at) {
      resumed = mark[i]
      break
    }
  }
  if (resumed < 0) next
  if (resumed > to) resumed = to
  why = (NF >= 2 && $2 != "") ? $2 : "paused"
  if (!(why in total)) order[++reasons] = why
  total[why] += resumed - at
}

END {
  for (i = 1; i <= reasons; i++)
    if (total[order[i]] > 0) printf "%s\t%d\n", order[i], total[order[i]]
}
