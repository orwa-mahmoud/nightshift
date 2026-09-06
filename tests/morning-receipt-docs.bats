README="$BATS_TEST_DIRNAME/../README.md"
DOC="$BATS_TEST_DIRNAME/../docs/morning-receipt.md"
PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
START="$PLUGIN/skills/start/SKILL.md"
TEMPLATES="$PLUGIN/skills/nightshift/references/receipts/cycle-specialist-evidence.md"

@test "the renderer's no-parser message is the one the skill tells the model to watch for" {
  grep -qF 'JSON parser unavailable' "$PLUGIN/runtime/morning-receipt.sh"
  grep -qF 'JSON parser unavailable' "$START"
}

@test "Start hands the model a receipt to write when the renderer has no parser" {
  grep -qF 'receipts/cycle-specialist-evidence.md' "$START"
  grep -qF 'morning-<YYYY-MM-DD>.md' "$START"
  grep -qF 'Every shift leaves a receipt.' "$START"
}

@test "the receipt templates carry the morning receipt block" {
  grep -qF '## Morning receipt' "$TEMPLATES"
  grep -qF '# Morning receipt' "$TEMPLATES"
  for field in '- Shift:' '- Ending:' '- Gates:' '- Verified:' '- Disabled by owner:' \
    '- Unavailable:'; do
    grep -qF -- "$field" "$TEMPLATES" || { echo "missing field: $field"; return 1; }
  done
}

@test "README links the morning receipt doc from the receipts section" {
  grep -qF '[Morning receipt](docs/morning-receipt.md)' "$README"
}

@test "morning-receipt doc covers every section, view, and the zero-gate line" {
  for heading in '## What each section means' '## Which view is for whom' '## Determinism'; do
    grep -qF "$heading" "$DOC" || { echo "missing: $heading"; return 1; }
  done
  grep -qF '**Shift**' "$DOC"
  grep -qF '**Baseline**' "$DOC"
  grep -qF '**What changed**' "$DOC"
  grep -qF '**Parked**' "$DOC"
  grep -qF '**Unsupported / unmeasured**' "$DOC"
  grep -qF '**Next**' "$DOC"
  grep -qF '`Verified:`' "$DOC"
  grep -qF '`Disabled by owner:`' "$DOC"
  grep -qF '`Unavailable:`' "$DOC"
  grep -qF 'Verified: none — verification level none (owner)' "$DOC"
  grep -qF '**owner**' "$DOC"
  grep -qF '**reviewer**' "$DOC"
  grep -qF '**release**' "$DOC"
  grep -qF '**artifact**' "$DOC"
  grep -qF 'no git terminology appears' "$DOC"
  grep -qF 'invents nothing' "$DOC"
  grep -qF 'never upgraded into proof' "$DOC"
  grep -qF 'runtime/morning-receipt.sh' "$DOC"
  grep -qF 'runtime/windows/morning-receipt.ps1' "$DOC"
  grep -qF '.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md' "$DOC"
  grep -qF '.nightshift/receipts/morning-<YYYY-MM-DD>.md' "$DOC"
}

@test "morning-receipt doc separates an absent policy from a chosen level of none" {
  grep -qF 'no shift policy was written' "$DOC"
  grep -qF "punch list's \`## Gates\`" "$DOC"
}

@test "morning-receipt doc claims nothing Status does not print" {
  if grep -qF 'Status prints the first section' "$DOC"; then
    return 1
  fi
}

@test "morning-receipt doc names no competing tool" {
  if grep -qiE 'copilot|windsurf|cline|devin|aider' "$DOC"; then
    return 1
  fi
}
