E="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/compose/shifts/documentation-media-accuracy.md"

@test "documentation media accuracy is finite and limited to owner-selected assets" {
  grep -qE '^# Documentation media accuracy — finite — ' "$E"
  grep -qi 'owner names' "$E"
  grep -qi 'owner-selected asset' "$E"
  grep -qi 'identified local build' "$E"
}

@test "documentation media accuracy requires a reproducible local app and build" {
  grep -qi 'existing local environment and dependencies' "$E"
  grep -qi 'checked-out commit and app version' "$E"
  grep -qi 'existing capture procedure' "$E"
}

@test "documentation media accuracy refuses remote inspection and credentials" {
  grep -qi 'Never fetch or inspect a public website or remote asset' "$E"
  grep -qi 'use credentials' "$E"
  grep -qi 'install new tools or dependencies' "$E"
}

@test "documentation media accuracy refuses fabricated evidence and product changes" {
  grep -qi 'Never use generated, edited, stock, or mock images' "$E"
  grep -qi 'Never change product code or behavior' "$E"
  grep -qi 'remove an original asset' "$E"
  grep -qi 'publish or deploy media' "$E"
}

@test "documentation media accuracy parks unverified assets with an evidence gap" {
  grep -qi 'park that asset with the missing evidence' "$E"
  grep -qi 'park the asset' "$E"
  grep -qi 'specific evidence gap' "$E"
}

@test "documentation media accuracy declares a testable ending and artifact boundary" {
  grep -qi 'Ends when every owner-selected asset' "$E"
  grep -qi 'Never select this entry in artifact mode' "$E"
  grep -qi 'Supported stacks' "$E"
}

@test "documentation media accuracy verifies the selected flow and touched pages" {
  grep -qi 'documented build and UI smoke-test commands' "$E"
  grep -qi 'reopen every touched documentation page' "$E"
  grep -qi 'Report the exact commands and results' "$E"
  grep -qi 'source commit, flow, and result in the item receipt' "$E"
}

@test "documentation media accuracy deduplicates rejected findings" {
  grep -qF 'snag-log.md (ALL seen — fixed and rejected)' "$E"
}
