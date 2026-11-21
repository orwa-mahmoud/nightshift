#!/usr/bin/env bash
# Run one shard of the bats suite.
# Usage: tests/run-shard.sh SHARD TOTAL [--list|--balance-report]
#   SHARD            — 1-indexed shard number
#   TOTAL            — number of shards (CI matrix size or local parallel job count)
#   --list           — print assigned files and exit
#   --balance-report — print the schedule replay for this file list and exit
#
# Files are enumerated in locale-independent path order and packed onto the
# shard with the smallest historical cost. The cost of a file is the median of
# its samples in tests/shard-timings/<platform>.tsv and <platform>-*.tsv.
# A file with no sample takes the median of the known costs, and at least one
# second, so a new file is neither free nor larger than the known set.
# With no samples every file weighs the same and the packing is round-robin.
set -euo pipefail

usage() {
  echo "usage: tests/run-shard.sh SHARD TOTAL [--list|--balance-report]" >&2
}

shard="${1:?shard number required (1-indexed)}"
total="${2:?total shards required}"
mode=run
case "${3:-}" in
  "") mode=run ;;
  --list) mode=list ;;
  --balance-report) mode=report ;;
  *)
    usage
    exit 2
    ;;
esac

case "$shard$total" in
  *[!0-9]*)
    usage
    exit 2
    ;;
esac

if [ "$shard" -lt 1 ] || [ "$shard" -gt "$total" ] || [ "$total" -lt 1 ]; then
  echo "shard must be 1..$total" >&2
  exit 2
fi

invoke="$(pwd)"
abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$invoke/$1" ;;
  esac
}

platform=other
if [ -n "${NIGHTSHIFT_SHARD_PLATFORM:-}" ]; then
  platform="$NIGHTSHIFT_SHARD_PLATFORM"
else
  case "$(uname -s)" in
    Darwin) platform=macos ;;
    Linux) platform=linux ;;
  esac
fi

timing_dir="tests/shard-timings"
if [ -n "${NIGHTSHIFT_SHARD_TIMINGS:-}" ]; then
  timing_dir="$(abs_path "$NIGHTSHIFT_SHARD_TIMINGS")"
fi
file_list_src=""
if [ -n "${NIGHTSHIFT_SHARD_FILES:-}" ]; then
  file_list_src="$(abs_path "$NIGHTSHIFT_SHARD_FILES")"
fi

have_before=0
before_work=0
classified="${NIGHTSHIFT_CLASSIFIED_AT:-}"
case "$classified" in
  ""|*[!0-9]*) ;;
  *)
    now="$(date +%s)"
    if [ "$now" -ge "$classified" ]; then
      before_work=$((now - classified))
      have_before=1
    fi
    ;;
esac

cd "$(dirname "$0")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ns-shard.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if [ -n "$file_list_src" ]; then
  LC_ALL=C sort -u "$file_list_src" | sed '/^$/d' >"$tmp/files"
else
  find tests -name '*.bats' | LC_ALL=C sort >"$tmp/files"
fi

if [ ! -s "$tmp/files" ]; then
  echo "no bats tests yet" >&2
  exit 0
fi

# A comment keeps the samples file non-empty. An empty first file would make
# awk treat the file list as the samples.
printf '# samples\n' >"$tmp/samples"
if [ -d "$timing_dir" ]; then
  for sample in "$timing_dir/$platform.tsv" "$timing_dir/$platform"-*.tsv \
    "$timing_dir/observed/$platform"-shard-*.tsv; do
    [ -f "$sample" ] || continue
    cat "$sample" >>"$tmp/samples"
  done
fi

# path, median seconds, in file-list order. Unknown files take the median of
# the known medians, floored at 1.
awk '
  function insort(n,    i, j, tmp) {
    for (i = 2; i <= n; i++) {
      tmp = v[i]
      j = i - 1
      while (j >= 1 && v[j] > tmp) {
        v[j + 1] = v[j]
        j--
      }
      v[j + 1] = tmp
    }
  }
  function med(n,    i) {
    if (n <= 0) return 1
    for (i = 1; i <= n; i++) v[i] = a[i]
    insort(n)
    if (n % 2 == 1) return v[(n + 1) / 2]
    return int((v[n / 2] + v[n / 2 + 1]) / 2)
  }
  BEGIN { FS = "\t" }
  NR == FNR {
    if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) next
    if ($1 != "" && $2 ~ /^[0-9]+$/) {
      c[$1]++
      s[$1, c[$1]] = $2 + 0
    }
    next
  }
  {
    if ($0 ~ /^[[:space:]]*$/) next
    files[++nfiles] = $0
  }
  END {
    kn = 0
    for (p in c) {
      for (i = 1; i <= c[p]; i++) a[i] = s[p, i]
      known[++kn] = med(c[p])
      kw[p] = known[kn]
    }
    fb = 1
    if (kn > 0) {
      for (i = 1; i <= kn; i++) a[i] = known[i]
      fb = med(kn)
    }
    if (fb < 1) fb = 1
    for (i = 1; i <= nfiles; i++) {
      p = files[i]
      w = (p in kw) ? kw[p] : fb
      printf "%s\t%d\n", p, w
    }
  }
' "$tmp/samples" "$tmp/files" >"$tmp/weights"

# Longest-first: heaviest file onto the lightest shard, lowest shard on a tie.
# Round-robin walks the same paths in order, which is what equal weights do.
LC_ALL=C sort -t "$(printf '\t')" -k2,2nr -k1,1 "$tmp/weights" >"$tmp/by-weight"

loads=""
rr=""
i=0
while [ "$i" -lt "$total" ]; do
  loads="$loads 0"
  rr="$rr 0"
  i=$((i + 1))
done
loads="${loads# }"
rr="${rr# }"

# shellcheck disable=SC2086
add_load() {
  _out=""
  _i=0
  for _load in $1; do
    if [ "$_i" -eq "$2" ]; then
      _load=$((_load + $3))
    fi
    _out="$_out $_load"
    _i=$((_i + 1))
  done
  printf '%s\n' "${_out# }"
}

# shellcheck disable=SC2086
lightest() {
  _best=0
  _best_load=""
  _i=0
  for _load in $1; do
    if [ -z "$_best_load" ] || [ "$_load" -lt "$_best_load" ]; then
      _best=$_i
      _best_load=$_load
    fi
    _i=$((_i + 1))
  done
  printf '%s\n' "$_best"
}

: >"$tmp/assigned"
while IFS="$(printf '\t')" read -r path weight; do
  slot="$(lightest "$loads")"
  loads="$(add_load "$loads" "$slot" "$weight")"
  printf '%s\t%s\n' "$((slot + 1))" "$path" >>"$tmp/assigned"
done <"$tmp/by-weight"

idx=0
while IFS="$(printf '\t')" read -r path weight; do
  slot=$((idx % total))
  rr="$(add_load "$rr" "$slot" "$weight")"
  idx=$((idx + 1))
done <"$tmp/weights"

awk -F '\t' -v shard="$shard" '$1 == shard { print $2 }' "$tmp/assigned" \
  | LC_ALL=C sort >"$tmp/selected"

if [ "$mode" = list ]; then
  if [ -s "$tmp/selected" ]; then
    cat "$tmp/selected"
  fi
  exit 0
fi

if [ "$mode" = report ]; then
  count="$(wc -l <"$tmp/files" | tr -d ' ')"
  packed_longest=0
  rr_longest=0
  for load in $loads; do
    if [ "$load" -gt "$packed_longest" ]; then
      packed_longest=$load
    fi
  done
  for load in $rr; do
    if [ "$load" -gt "$rr_longest" ]; then
      rr_longest=$load
    fi
  done
  printf 'platform %s\n' "$platform"
  printf 'files %s\n' "$count"
  printf 'packed_longest %s\n' "$packed_longest"
  printf 'round_robin_longest %s\n' "$rr_longest"
  n=1
  for load in $loads; do
    printf 'packed_shard %s %s\n' "$n" "$load"
    n=$((n + 1))
  done
  n=1
  for load in $rr; do
    printf 'round_robin_shard %s %s\n' "$n" "$load"
    n=$((n + 1))
  done
  while IFS="$(printf '\t')" read -r path weight; do
    printf 'weight %s %s\n' "$path" "$weight"
  done <"$tmp/weights"
  exit 0
fi

count="$(wc -l <"$tmp/selected" | tr -d ' ')"
work=0
status=0
job_start="$(date +%s)"
: >"$tmp/file-times"
if [ "$count" -gt 0 ]; then
  while IFS= read -r file; do
    start="$(date +%s)"
    rc=0
    bats "$file" || rc=$?
    end="$(date +%s)"
    dur=$((end - start))
    work=$((work + dur))
    if [ "$status" -eq 0 ] && [ "$rc" -ne 0 ]; then
      status=$rc
    fi
    printf '  %s %ss\n' "$file" "$dur" | tee -a "$tmp/file-times" >&2
    if [ "${NIGHTSHIFT_SHARD_RECORD:-1}" != 0 ]; then
      mkdir -p "$timing_dir/observed"
      printf '%s\t%s\n' "$file" "$dur" >>"$timing_dir/observed/${platform}-shard-${shard}.tsv"
    fi
  done <"$tmp/selected"
fi
job_end="$(date +%s)"
wall=$((job_end - job_start))
summary="shard $shard/$total: $count file(s), platform $platform, work ${work}s, wall ${wall}s"
if [ "$have_before" -eq 1 ]; then
  summary="$summary, before_work ${before_work}s"
fi
echo "$summary" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Shard %s/%s (%s)\n\n' "$shard" "$total" "$platform"
    printf '%s\n\n' "$summary"
    cat "$tmp/file-times"
    printf '\n'
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$status"
