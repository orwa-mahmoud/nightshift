E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/standing-loop.md"
T="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/templates/product-research.md"

@test "product evolution ends only at the deadline, never by convergence" {
  grep -qi 'deadline is the ONLY thing' "$E"
  grep -qiE 'too shallow' "$E"
}

@test "product evolution is research-led rather than a lint loop" {
  grep -qi 'product-research.md' "$E"
  grep -qi 'opportunity-map.md' "$E"
  grep -qF 'receipts/cycle-specialist-evidence.md' "$E"
  grep -qi 'small validated slices' "$E"
  grep -qi 'disproved by prior receipts' "$E"
  grep -qi 'rather than supplying the roadmap' "$E"
}

@test "product evolution researches safely and records sources" {
  grep -qi 'dated source' "$E"
  grep -qi 'private code' "$E"
  grep -qi "copy a competitor's" "$E"
  grep -qi 'work-target evidence' "$E"
  grep -qi 'work-target evidence' "$T"
}

@test "product evolution permits substantial work without external publication" {
  grep -qi 'substantial' "$E"
  grep -qi 'push, open a PR, deploy, publish' "$E"
  grep -qi 'dedicated nightshift branch' "$E"
  grep -qF 'nightshift/<short-purpose>-<YYYY-MM-DD>' "$E"
  grep -qF 'isolated-branch' "$E"
  grep -qF 'do not `git init` the folder' "$E"
  grep -qi 'artifact receipt' "$E"
  grep -qF '$NS/receipts/' "$E"
}

@test "product evolution leaves an evidence-backed morning handoff" {
  grep -qi 'handoff covering research' "$E"
  grep -qi 'traces to evidence' "$E"
}

@test "product evolution resumes the single active opportunity before exploring" {
  grep -qi 'if opportunity-map.md has a building entry' "$E"
  grep -qi 'Never open a second building opportunity' "$E"
  grep -qi 'exact next action' "$E"
  grep -qi 'verification; continue that opportunity' "$E"
}

@test "the active opportunity is refreshed at meaningful boundaries, not every command" {
  grep -qi 'meaningful boundaries' "$E"
  grep -qi 'Do not rewrite it after every command' "$E"
  grep -qi 'snag log as a progress journal' "$E"
}
