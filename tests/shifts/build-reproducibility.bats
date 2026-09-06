E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/build-reproducibility.md"
HUNT="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/hunt/SKILL.md"

@test "build reproducibility follows declared clean setup paths" {
  grep -qi 'Discovery' "$E"
  grep -qi 'declared clean setup and build paths' "$E"
  grep -qi 'repository-owned commands' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
}

@test "build reproducibility inventories artifacts and compares determinism honestly" {
  grep -qi 'artifact' "$E"
  grep -qi 'digest' "$E"
  grep -qi 'determinism is expected' "$E"
  grep -qi 'cache-only success' "$E"
  grep -qi 'hidden environment' "$E"
}

@test "build reproducibility never imposes a new build stack" {
  grep -qi 'Never impose Docker' "$E"
  grep -qi 'package manager' "$E"
  grep -qi 'provenance' "$E"
  grep -qi 'build stack' "$E"
}

@test "build reproducibility refuses owner-only installs and honest environment limits" {
  grep -qi 'Refuse owner-only install' "$E"
  grep -qi 'clean room' "$E"
  grep -qi 'name the environment each run actually used' "$E"
  grep -qi 'Never claim a clean room' "$E"
}

@test "build reproducibility is finite repository mode with item gate" {
  head -n1 "$E" | grep -q '— finite —'
  grep -qi 'Never select this entry when work mode is artifact' "$E"
  grep -qi 'Ends when every declared path' "$E"
  grep -qi 'item gate is green at every commit' "$E"
  grep -qi 'snag-log.md' "$E"
}

@test "build reproducibility declares supported stacks" {
  grep -qi 'Supported on repositories' "$E"
  grep -qi 'Makefile' "$E"
}
