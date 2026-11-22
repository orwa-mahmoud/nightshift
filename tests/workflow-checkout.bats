#!/usr/bin/env bats
# A workflow step that runs a file from the repository needs the checkout before it in the same job.
# Runners start empty, and a step ordered before the checkout fails only on the path that runs it.

ROOT="$BATS_TEST_DIRNAME/.."

# repo_paths_before_checkout <workflow>... — `<file>:<line>: <job>` for each run line that names a
# repository path before that job's first checkout step.
repo_paths_before_checkout() {
  awk '
    FNR == 1 { in_jobs = 0; job = ""; run_indent = -1 }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[^[:space:]#]/ { in_jobs = 0 }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      job = $1; sub(/:$/, "", job); checked = 0; run_indent = -1; next
    }
    {
      indent = match($0, /[^ ]/) - 1
      if (run_indent >= 0 && indent <= run_indent && $0 ~ /[^[:space:]]/) run_indent = -1
    }
    /uses:[[:space:]]*actions\/checkout@/ { checked = 1; next }
    /^[[:space:]]*(- )?run:/ {
      line = $0
      run_indent = match($0, /[^ -]/) - 1
      sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", line)
      if (line !~ /^[|>]/ && !checked && line ~ /(^|[^A-Za-z0-9_.\/-])(\.\/)?(tests|plugins|\.github)\//)
        print FILENAME ":" FNR ": " job
      next
    }
    run_indent >= 0 && !checked && $0 ~ /(^|[^A-Za-z0-9_.\/-])(\.\/)?(tests|plugins|\.github)\// {
      print FILENAME ":" FNR ": " job
    }
  ' "$@"
}

@test "no workflow step runs a repository file before its job checks out the repository" {
  run repo_paths_before_checkout "$ROOT"/.github/workflows/*.y*ml
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'runs a repository path before checkout: %s\n' "$output"; return 1; }
}

@test "the check finds a script step ordered before the checkout" {
  wf="$BATS_TEST_TMPDIR/early.yml"
  cat >"$wf" <<'EOF'
on: pull_request
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - name: Skip the scan
        if: needs.changes.outputs.skills == 'false'
        run: |
          python3 tests/skill-scan-report.py --outcome skip
      - uses: actions/checkout@v4
      - run: bash tests/after.sh
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: bash .github/inline.sh
EOF
  run repo_paths_before_checkout "$wf"
  [ "$status" -eq 0 ]
  [ "$output" = "$wf:9: scan
$wf:15: lint" ]
}
