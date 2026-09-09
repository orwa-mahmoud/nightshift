# Maintainer verification matrix

Where each shipped surface lives and which tests hold it. Run the rows a change touches; the full
program is `tests/run-parallel.sh` or `bats -r tests/`, and CI runs the same partition as six
parallel `tests/run-shard.sh` jobs.

## Policy and shift lifecycle

| Surface | Runtime | Tests |
| --- | --- | --- |
| Rules reader (no `jq`, no `python3`) | `plugins/nightshift/lib/rules-read.sh`, `plugins/nightshift/lib/rules-read.awk` | `tests/rules-read.bats`, `tests/rules-schema.bats`, `tests/armed-no-python-jq.bats` |
| Three-layer policy | `plugins/nightshift/lib/policy.sh`, `plugins/nightshift/runtime/shift-policy.sh`, `plugins/nightshift/runtime/apply-profile.sh` | `tests/shift-policy.bats`, `tests/precedence.bats`, `tests/policy-matrix.bats`, `tests/rule-profiles.bats`, `tests/windows-shift-policy.bats` |
| Start preflight verdicts | `plugins/nightshift/runtime/start-preflight.sh`, `plugins/nightshift/runtime/windows/start-preflight.ps1` | `tests/start-preflight.bats`, `tests/shift-arming.bats` |
| Resolved policy view | `plugins/nightshift/runtime/doctor.sh`, `plugins/nightshift/runtime/status.sh`, `plugins/nightshift/runtime/export-support.sh` | `tests/doctor.bats`, `tests/status.bats`, `tests/support-bundle.bats` |
| Permission preflight and parking | `plugins/nightshift/runtime/preflight-needs.sh`, `plugins/nightshift/runtime/park-needs.sh` | `tests/preflight-needs.bats`, `tests/windows-preflight-needs.bats` |
| Auto-add seatbelt | `plugins/nightshift/runtime/provision.sh`, `plugins/nightshift/runtime/provision-recover.sh` | `tests/provisioning.bats`, `tests/provision-recover.bats`, `tests/windows-provision-recover.bats` |
| State version and migration | `plugins/nightshift/lib/state.sh`, `plugins/nightshift/runtime/migrate-state.sh` | `tests/state-version.bats`, `tests/state-counts.bats`, `tests/state-file-roles.bats` |
| Stop, reset, purge, control | `plugins/nightshift/lib/control.sh`, `plugins/nightshift/runtime/stop-shift.sh`, `plugins/nightshift/runtime/reset-shift.sh`, `plugins/nightshift/runtime/purge-workspace.sh` | `tests/control.bats`, `tests/windows-control.bats` |

## Evidence and receipts

| Surface | Runtime | Tests |
| --- | --- | --- |
| Findings ledger | `plugins/nightshift/runtime/evidence.sh`, `plugins/nightshift/runtime/windows/evidence.ps1` | `tests/evidence.bats`, `tests/windows-evidence.bats` |
| Comparison | `plugins/nightshift/runtime/evidence-compare.sh`, `plugins/nightshift/runtime/evidence-compare.jq` | `tests/evidence-compare.bats`, `tests/windows-evidence-compare.bats` |
| Morning receipt | `plugins/nightshift/runtime/morning-receipt.sh`, `plugins/nightshift/runtime/windows/morning-receipt.ps1` | `tests/morning-receipt.bats`, `tests/morning-receipt-docs.bats`, `tests/windows-morning-receipt.bats` |
| Artifact receipts and archive | `plugins/nightshift/runtime/archive-receipts.sh`, `plugins/nightshift/runtime/evidence-archive.sh` | `tests/artifact-receipts.bats`, `tests/archive-receipts.bats`, `tests/work-mode.bats` |
| Cited reports | `plugins/nightshift/runtime/check-report.sh` | `tests/cited-research.bats`, `tests/redaction-malicious.bats` |
| Cross-host handoff | `plugins/nightshift/runtime/continuity-handoff.sh` | `tests/continuity-handoff.bats` |
| Receipt templates the model writes from | `plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md` | `tests/quality-workflow.bats`, `tests/coverage-risk.bats`, `tests/defect-cycle.bats`, `tests/history-context.bats`, `tests/shift-planner.bats`, `tests/source-policy-evidence.bats`, `tests/specialist-evidence.bats` |

Schemas: `plugins/nightshift/skills/nightshift/references/schemas/v1/`. Fixtures: `tests/fixtures/`.

## Catalog and skills

| Surface | Tests |
| --- | --- |
| Catalog contracts, one file per entry | `tests/catalog.bats`, `tests/shifts/` |
| Every path a skill names resolves | `tests/skill-refs.bats`, `tests/skill-paths.bats` |
| Every path the docs name resolves | `tests/doc-refs.bats` |
| Selection and launch modes | `tests/shift-modes.bats`, `tests/walkthroughs.bats`, `tests/shift-planner.bats` |
| Contract schema and size budgets | `evals/run.sh`, `evals/validate.sh`, `tests/evals.bats` |
| Public claims stay honest | `tests/security-claims.bats`, `tests/workspace-docs.bats`, `tests/troubleshooting.bats` |

## Host parity and recovery

| Host | Watchman | Hooks and gate | Lifecycle |
| --- | --- | --- | --- |
| Claude Code (POSIX) | `plugins/nightshift/runtime/claude/watchman.sh` | `plugins/nightshift/hooks/`, `tests/hardhat.bats`, `tests/clock-out-gate.bats` | `tests/e2e-lifecycle.bats`, `tests/watchman.bats` |
| Codex | `plugins/nightshift/runtime/codex/watchman.sh` | `plugins/nightshift/hooks/codex/`, `tests/codex/` | `tests/e2e-lifecycle.bats`, `tests/codex/watchman.bats` |
| Cursor | `plugins/nightshift/runtime/cursor/watchman.sh` | `plugins/nightshift/hooks/cursor/`, `tests/cursor/` | `tests/cursor/watchman.bats` |
| Native Windows | `plugins/nightshift/runtime/windows/watchman.ps1` | `plugins/nightshift/hooks/windows/`, `tests/windows-hardhat.bats` | `tests/windows/run.ps1` (Windows CI) |

Shared hook cores: `plugins/nightshift/hooks/shared/gate-core.sh`,
`plugins/nightshift/hooks/shared/hardhat-core.sh` — `tests/shared-hook-cores.bats`,
`tests/hook-replay.bats`, `tests/hook-fuzz.bats`.

## Safety boundaries

| Boundary | Enforced by | Tests |
| --- | --- | --- |
| Clock-out with open boxes | `plugins/nightshift/hooks/clock-out-gate.sh` | `tests/clock-out-gate.bats`, `tests/windows-clock-out.bats` |
| Five elevation categories | `plugins/nightshift/lib/policy.sh` patterns, matched by hardhat and the preflight | `tests/hardhat.bats`, `tests/precedence.bats`, `tests/preflight-needs.bats` |
| One process owns the shift | `plugins/nightshift/lib/process.sh` | `tests/process-lease.bats`, `tests/process-evidence.bats` |
| Repository vs artifact mode | `plugins/nightshift/runtime/archive-receipts.sh` | `tests/work-mode.bats`, `tests/artifact-receipts.bats` |
| An armed shift with neither `jq` nor `python3` | rules reader, hooks | `tests/armed-no-python-jq.bats` |
| No Python ships in the plugin | `git ls-files 'plugins/nightshift/**/*.py'` | `tests/armed-no-python-jq.bats` |

## Quick smoke

```text
evals/run.sh
bats tests/evals.bats
claude plugin validate . --strict
git ls-files '*.sh' | xargs shellcheck -x
```

## Non-goals

- Central telemetry or hosted accounts
- Mandatory npm, Homebrew, or MCP for Setup → Start → tick
- Independent proof of a self-reported tick (by design)
- Competitor comparisons in public artifacts

Public documentation: [`docs/evidence-capabilities.md`](evidence-capabilities.md#evidence-and-receipts),
[`docs/how-it-works.md`](how-it-works.md#three-policy-layers-and-one-resolved-view).

---

[Read the contribution requirements](../CONTRIBUTING.md#contributing-to-nightshift) · [Documentation index](README.md#documentation)
