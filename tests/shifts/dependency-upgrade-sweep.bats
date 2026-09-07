E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/dependency-upgrade-sweep.md"

@test "dependency upgrade sweep batches with engineering evidence" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

# A version bump that compiles is not an upgrade. The release notes are the work, and skipping
# them is how a green gate hides a behaviour change nobody read about.
@test "the upgrade sweep reads the release notes and adapts the code" {
  grep -qi 'release notes and migration guide FIRST' "$E"
  grep -qi 'adapt the code' "$E"
}

# Without a bound, one bad major eats the night and leaves the tree half-migrated — worse than the
# old version it replaced.
@test "the upgrade sweep bounds a single major" {
  grep -qi 'Time-box a major' "$E"
  grep -qi 'revert clean and park' "$E"
}

@test "the upgrade sweep refuses prereleases and stays on direct dependencies" {
  grep -qi 'Never take a prerelease' "$E"
  grep -qi 'Direct dependencies only' "$E"
}

# One package per commit is what makes a failing gate diagnosable at 4am.
@test "the upgrade sweep commits one package at a time, safest first" {
  grep -qi 'One package per commit' "$E"
  grep -qi 'patches, then minors, then majors' "$E"
}

# A gate can only prove what it covers, so a thinly tested core package is a park, not a claim.
@test "the upgrade sweep does not mistake a green gate for proof" {
  grep -qi 'proves only what it covers' "$E"
}

@test "the upgrade sweep leaves owner decisions to the owner" {
  grep -qi 'Never hand-edit the lockfile' "$E"
  grep -qi 'never change the package' "$E"
}
