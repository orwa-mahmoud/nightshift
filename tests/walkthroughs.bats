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
  # over — a list in prose beside a list in code is two lists that can disagree.
  for m in STOP .stall .notified .ended deadline .session-end .shift-pulse .mint-failed .shift-session .watchman-tick .watchman .lock.d; do
    grep -qF "$m" "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh" || { echo "the preflight does not clear $m"; return 1; }
  done
}

# A spent deadline strands tonight's shift; a future one IS tonight's plan, and since start never
# asks for hours, deleting it would leave a walkthrough that can never be given a clock.
@test "start clears only a deadline that has already passed" {
  grep -qi 'deadline is cleared only if it has already passed' "$START"
  grep -qi 'still in the future is tonight' "$START"
}

# With work queued, start must be silent — that is what lets cron run it and the watchman revive
# it. It speaks only when there is nothing to work, where silence would be useless instead of safe.
@test "start is silent when the punch list has work" {
  grep -qi 'this command asks nothing' "$START"
  grep -qi 'never asked' "$START"         # the deadline is read, not requested
  grep -qi 'punch list is the shift' "$START"
  grep -qi 'promotes nothing on its own' "$START"
}

# A parked order is parked. start cutting it unasked would surprise an owner who deliberately
# said "later" — so the offer happens only when there is no other work.
@test "start promotes nothing unless the punch list is empty" {
  grep -qi 'do not promote, cut, or add anything' "$START"
  grep -qi 'only when the punch list is empty' "$START"
  grep -qi 'drafting-table.md' "$START"
}

# Imported issues carry review flags the helper enforces. A hand-edit of the two markdown files
# would skip that, so empty-list Start must use the same promote path Hunt already names.
@test "start cuts a proposed import in the skill" {
  grep -qF 'Status: proposed' "$START"
  grep -qF 'drafting table' "$START"
  grep -qi 'Do not require Python' "$START"
  grep -qi 'flagged import stays refused' "$START"
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

# An item in two files is an item that gets worked twice, or ticked in the wrong place.
@test "a cut moves the item and never copies it" {
  grep -qi 'move, never copy' "$START"
  grep -qi 'never exists in two places' "$START"
  grep -qi 'never a copy' "$HUNT"
  grep -qi 'must not exist in two places' "$HUNT"
}

# The one thing start may still do is refuse — a walkthrough without a clock never ends.
@test "start refuses an open-ended item that has no deadline" {
  grep -qi 'refuse to start' "$START"
  grep -qi 'never invent a number' "$START"
}

@test "start writes the deadline from a cut order's recorded hours" {
  grep -q 'work-orders.md' "$START"
  grep -q 'hours\*3600' "$START"
  grep -qF 'date +%s' "$START"
  grep -qF 'Get-NSUnixTime' "$START"
  grep -q 'hours\*3600' "$HUNT"
  grep -qF 'date +%s' "$HUNT"
  grep -qF 'Get-NSUnixTime' "$HUNT"
  # Setup provides the orders file by scaffolding it from the templates directory.
  [ -f "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/templates/work-orders.md" ]
}

# Entries are files in a directory, so hunt must discover from it. Reciting from memory is how a
# shift that shipped last week never reaches the owner who could have used it tonight — and
# reading all thirty contracts to offer one is the other way to get that wrong.
@test "hunt composes from the catalog directory and may pick more than one" {
  grep -qF 'references/compose/shifts/' "$HUNT"
  grep -qE 'ns"? catalog-index' "$HUNT"
  grep -qi 'an entry added today is discovered today' "$HUNT"
  grep -qi 'more than one may be chosen' "$HUNT"
  grep -qi 'list the directory and read the entries yourself' "$HUNT"
}

# Hours are mandatory only where nothing else can end the shift. Where the work has a natural
# end, the owner gets a real either/or rather than a silent default.
@test "hunt asks for hours only where the ending needs them" {
  grep -qi 'hours are REQUIRED' "$HUNT"
  grep -qi 'explicit either/or' "$HUNT"
  grep -qi 'capped at N hours' "$HUNT"
}

# Owner scope is what turns a generic preset into a shift worth running — but it must never be
# able to rewrite the contract that governs the shift.
@test "hunt takes owner instructions without overwriting the contract" {
  grep -qi 'scope or approach' "$HUNT"
  grep -qF 'Owner instructions:' "$HUNT"
  grep -qi 'never edit the entry' "$HUNT"
  grep -qi 'adds constraints rather than replacing them' "$HUNT"
}

@test "hunt shows the assembled shift before anything is written" {
  grep -qi 'exactly as they will be written' "$HUNT"
  grep -qi 'last look before anything is armed' "$HUNT"
}

@test "hunt writes the order and its hours to work-orders.md, and never clobbers" {
  grep -q 'work-orders.md' "$HUNT"
  grep -q 'Hours:' "$HUNT"
  grep -qi 'never clobber' "$HUNT"
  grep -qi 'clock starts only at the cut' "$HUNT"
}

# Work is composed in one command and started in another; duplicating the cut is how the two
# drifted apart the first time.
# Selecting a shift and saying "now" must start it — not print an instruction to run another
# command. The owner already answered the only question that mattered.
@test "hunt starts the shift itself on now, and parks it on later" {
  grep -qi 'start the shift yourself, here' "$HUNT"
  grep -qi 'without making the owner type another command' "$HUNT"
  grep -qi 'arm the watchman' "$HUNT"
  grep -qi 'park it for later' "$HUNT"
}

@test "Start and Hunt name artifact receipts in the live work loop" {
  # Start hands the item loop to the main skill, which is where the gate rule belongs.
  grep -qF 'Gate' "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/SKILL.md"
  grep -qF 'gate green at every commit or artifact receipt' "$HUNT"
}

@test "hunt Automatic treats a complete prompt as binding intent" {
  grep -qF 'use the next 20 hours adding features and enhancing existing ones' "$HUNT"
  grep -qF '8 hours clear lint and test debt' "$HUNT"
  grep -qF 'Ask only a field that is still missing' "$HUNT"
  if grep -qF 'shift-planner' "$HUNT"; then
    return 1
  fi
  if grep -qF 'shift-preview' "$HUNT"; then
    return 1
  fi
  if grep -qF 'python3' "$HUNT"; then
    return 1
  fi
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

@test "hunt separates selection mode from launch mode" {
  grep -qi 'Guided' "$HUNT"
  grep -qi 'Automatic' "$HUNT"
  grep -qi 'review first, or run directly' "$HUNT"
  grep -qi 'independent from Guided or Automatic' "$HUNT"
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
  grep -qF 'stay exactly where they are' "$s"      # open items + contract stay
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

@test "status, start, and hunt name leftover contract on an empty punch list" {
  # The inspector states it and Status relays it: a punch list with nothing open still carries a
  # contract that binds the next cut.
  grep -qF 'leftover Shift contract and Gates still bind' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
  # Drafts are counted only after the rule, so the shipped example is not a staged draft.
  grep -qF 'ns_open_drafts' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'Shift contract and Gates' "$START"
  grep -qF 'Shift contract and Gates' "$HUNT"
  grep -qF 'parking-lot.md' "$HUNT"
}
