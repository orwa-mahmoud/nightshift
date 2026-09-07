E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/clear-quality-debt.md"

# This entry works the same findings /nightshift:quality only reports. It must fix causes, never
# silence them — the one failure mode that would make a quality shift worse than nothing.
@test "the quality-debt entry fixes causes and never silences" {
  grep -qi 'never silence instead of fixing' "$E"
  grep -qi 'no new suppressions' "$E"
  grep -qi 'snag-log.md' "$E"
}
