HUNT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/hunt/SKILL.md"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"

# The catalog's own rules live in catalog.bats (structural, globbed) and tests/shifts/<entry>.bats
# (one file per entry), so adding a shift never edits a test file someone else is also editing.

# Both entry points into a live shift must clear the same leftovers. They drifted once: start
# cleared three markers, hunt's cut cleared none, so a spent deadline or a leftover STOP from
# last night silently ended the next shift at its first stop attempt. Now only start cuts, so
# only start clears — and it must still name every marker.
@test "start clears every stale marker" {
  # The preflight clears them, and Start stopped listing what it clears when the helper took it
  # over — a list in prose beside a list in code is two lists that can disagree. Each marker is
  # named by its layout key, so the list holds whichever layout the workspace keeps.
  pre="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  control="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/control.sh"
  reported="$(grep -F 'for key in stop stall' "$pre")"
  dropped="$(awk '/^ns_control_drop_runtime_markers\(\)/,/^}/' "$control" | tr '\n\\' '  ')"
  for key in stall notified ended session-end pulse mint-failed idle-watch session watchman-tick lock; do
    case " ${reported%%;*} " in *" $key "*) ;; *) echo "the preflight does not report $key"; return 1 ;; esac
    case "$dropped" in *" $key "* | *" $key;"*) ;; *) echo "the preflight does not clear $key"; return 1 ;; esac
  done
  grep -qF 'ns_control_drop "$STOP"' "$pre"
  grep -qF 'ns_control_drop "$DEADLINE"' "$pre"
  grep -qF 'ns_control_stop_watchman "$NS"' "$pre"
}

# With work queued, start must be silent — that is what lets cron run it and the watchman revive
# it. It speaks only when there is nothing to work, where silence would be useless instead of safe.
@test "start is silent when the punch list has work" {
  grep -qi 'this command asks nothing' "$START"
  grep -qi 'never asked' "$START"         # the deadline is read, not requested
  grep -qi 'punch list is the shift' "$START"
  grep -qi 'promotes nothing on its own' "$START"
}

# Hunt writes a heading plus hours plus the item. Cutting only the checkbox leaves an empty
# order that Doctor no longer counts and Archive has to guess about.
@test "a work-order cut removes the whole section" {
  grep -qF 'whole `## Work order` section' "$START"
  grep -qF 'whole `## Work order` section' "$HUNT"
  grep -qF 'order heading behind' "$HUNT"
  grep -qi 'leftover shell from a cut' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
}

@test "quality routes a feature objective to Hunt and drops Python compose" {
  quality="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/quality/SKILL.md"
  grep -qF 'continue as Hunt / Product Evolution' "$quality"
  grep -qF 'Do not show Quality catalog cards' "$quality"
  if grep -qF 'shift-planner' "$quality"; then
    return 1
  fi
  if grep -qF 'shift-preview' "$quality"; then
    return 1
  fi
  grep -qF 'unavailable' "$quality"
  if grep -qF 'python3' "$quality"; then
    return 1
  fi
  if grep -qF 'runtime/quality-workflow.sh' "$quality"; then
    return 1
  fi
}

@test "automatic hunt ranks evidence and uses one combined clock" {
  mode="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
  quality="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/quality/SKILL.md"
  grep -qi 'inspect the work target' "$mode"
  grep -qi 'inspect the work target' "$HUNT"
  grep -qF '$NS/receipts/' "$HUNT"
  # The refusals are the preflight's; Hunt points at it, and the preflight explains each one.
  grep -qF 'Compose, cut and arm only through the Start preflight' "$HUNT"
  explain="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'explain	receipts	' "$explain"
  grep -qF 'explain	work-mode	' "$explain"
  grep -qF 'explain	work-target	' "$explain"
  grep -qi 'artifact mode' "$mode"
  grep -qi 'do not require a git history' "$mode"
  grep -qF 'Compose, cut and arm only through the Start preflight' "$mode"
  grep -qF 'Never `git init` a notes folder' "$mode"
  grep -qi 'Skip the GitHub issue hunt when work mode is artifact' "$mode"
  grep -qi 'Skip the defect hunt when work mode is artifact' "$mode"
  grep -qi 'Skip documentation drift when work mode is artifact' "$mode"
  grep -qi 'Skip TODO and FIXME debt when work mode is artifact' "$mode"
  grep -qi 'Skip coverage hunt when work mode is artifact' "$mode"
  grep -qi 'Skip tooling quality-debt entries when work mode is artifact' "$mode"
  grep -qi 'applicable only when the work target can supply' "$mode"
  grep -qi 'do not require git history' "$quality"
  grep -qF '$NS/receipts/' "$quality"
  # The refusals are the preflight's; Quality points at it, and the preflight explains each one.
  grep -qF 'Compose, cut and arm only through the Start preflight' "$quality"
  grep -qi 'artifact mode' "$quality"
  grep -qF 'Never `git init` a notes folder' "$quality"
  grep -qi 'owner'\''s sentence is binding intent' "$mode"
  grep -qi 'model is the planner' "$mode"
  grep -qi 'do not hijack' "$mode"
  grep -qi 'Remove overlaps' "$mode"
  grep -qi 'Run finite entries first' "$mode"
  grep -qi 'at most one open-ended entry' "$mode"
  grep -qi 'one deadline governs' "$mode"
}

@test "review-first and run-direct clocks begin at different boundaries" {
  mode="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
  grep -qi 'clock starts only after' "$mode"
  grep -qi 'Start the clock immediately' "$mode"
  grep -qi 'Guided + run directly' "$mode"
}

@test "run-direct has a bounded decision policy and leaves receipts" {
  mode="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/shift/direct-mode-decisions.md"
  grep -qi 'production-quality default' "$mode"
  grep -qi 'parking-lot.md' "$mode"
  grep -qi 'rollback' "$mode"
  grep -qi 'publishing' "$mode"
  grep -qi 'legal or licensing policy' "$mode"
  # Where the work lands is a composition decision, so it stayed with the composition text.
  grep -qi 'isolated branch or inside the artifact work target' "$mode"
  compose="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/execution-modes.md"
  grep -qi 'one branch or artifact work target' "$compose"
  grep -qF 'one set of receipts' "$compose"
  grep -qF '.nightshift/receipts/' "$compose"
}

# The archive files finished paperwork only — the contract and open work are untouchable.
@test "the archive skill moves only finished records, never the contract or open items" {
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
  [ -f "$s" ]
  grep -qF 'Open items, the contract and the gates stay live' "$s"  # open items + contract stay
  grep -qF 'never ticks a box' "$s"                # files paperwork, does no work
  grep -qF 'archive/<YYYY-MM-DD>/' "$s"            # dated folders are the shape
  grep -qF 'date +%Y-%m-%d' "$s"
  grep -qF 'Get-Date -Format yyyy-MM-dd' "$s"
  grep -qF 'date +%Y-%m-%d' "$START"
  grep -qF 'Get-Date -Format yyyy-MM-dd' "$START"
  grep -qF 'unanswered stay' "$s"                  # open questions are not history
  grep -qF 'product-research.md' "$s"             # completed research is preserved
  grep -qF '`candidate`, `building`, and `parked`' "$s" # nonterminal opportunities stay live
  grep -qF 'leftover Shift contract and Gates' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/archive/SKILL.md"
  grep -qF '## Notes' "$s"
  grep -qF 'Never write' "$s"
  grep -qF 'git -C "$NS"' "$s"
  grep -qF 'user.email=nightshift@localhost' "$s"
  grep -qF 'commit.gpgsign=false' "$s"
}

@test "status surfaces the active product cycle without mutating it" {
  # Status renders what the helper prints: the building entry's phase, next action and remaining
  # verification, read without touching the map.
  s="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'fact "building $key"' "$s"
  grep -qF 'ns_status_building' "$s"
}
