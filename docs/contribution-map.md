# Choose your contribution

Nightshift accepts documentation, tests, shell, recovery, platform, and shift-catalog work. Start
with the row that matches what you already know, then read
[`CONTRIBUTING.md`](../CONTRIBUTING.md) before changing files.

If no linked issue fits, open an issue before doing anything beyond a typo or small fix. The
[good first issue list](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
is the shortest current queue.

## Pick a path

| Area | A good first contribution | Know before starting | Likely files | Minimum verification | Current work |
| --- | --- | --- | --- | --- | --- |
| **Shift catalog** | Add one narrow, reusable night shift | Markdown, a concrete definition of done, and the failure modes the shift must refuse | `plugins/nightshift/skills/nightshift/references/compose/shifts/`, `tests/shifts/` | `bats tests/catalog.bats` plus the matching file under `tests/shifts/`; for priority contracts also `evals/validate.sh` and `tests/evals.bats` (schema and size budgets) | [Propose a shift](https://github.com/orwa-mahmoud/nightshift/issues/new?template=catalog_shift.yml) or join [#21](https://github.com/orwa-mahmoud/nightshift/issues/21) |
| **Documentation** | Shorten a path to a first successful shift or document a verified layout | The behavior being documented; reproduce every command you change | `README.md`, `docs/`, `examples/`, skill `SKILL.md` files | Run the focused contract test when one exists: `bats tests/doc-refs.bats tests/contribution-map.bats tests/first-night-checklist.bats tests/shift-modes.bats tests/troubleshooting.bats tests/bad-night-template.bats tests/github-templates.bats`; then `claude plugin validate . --strict` | [Open documentation work](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22area%3A+docs%22) |
| **Testing** | Add a regression for one observed failure | Bats and the shell or skill contract under test | `tests/*.bats`, `tests/codex/`, `tests/fixtures/` | Run the changed Bats file directly, then `bats tests/` | Check [open testing work](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22area%3A+testing%22); if the queue is empty, propose one reproducible gap first |
| **Runtime** | Fix a diagnosed setup, state, scheduling, import, or support-bundle problem | Portable Bash 3.2, filesystem safety, and the matching runtime contract | `plugins/nightshift/runtime/`, `plugins/nightshift/lib/lib.sh`, `plugins/nightshift/lib/Nightshift.psm1`, matching `tests/*.bats` | Run the matching Bats file, then `bats tests/` and `git ls-files '*.sh' \| xargs shellcheck -x` | [Open runtime work](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22area%3A+runtime%22) |
| **Recovery** | Add evidence for an observed recovery failure or fix a proven classification bug | Process evidence, session identity, process leases, transcripts, and conservative stand-down behavior | `plugins/nightshift/runtime/claude/watchman.sh`, `plugins/nightshift/runtime/codex/watchman.sh`, `plugins/nightshift/runtime/cursor/watchman.sh`, `plugins/nightshift/runtime/windows/watchman.ps1`, `plugins/nightshift/runtime/windows/start-watchman.ps1`, `tests/watchman.bats`, `tests/codex/watchman.bats`, `tests/cursor/watchman.bats`, `tests/windows-watchman.bats`, `tests/process-lease.bats` | `bats tests/watchman.bats tests/codex/watchman.bats tests/cursor/watchman.bats tests/windows-watchman.bats tests/process-lease.bats tests/process-evidence.bats tests/degradation.bats tests/watch-reason.bats tests/e2e-lifecycle.bats` and shellcheck for changed scripts | [Open recovery work](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22area%3A+recovery%22) |
| **Hooks and guards** | Fix a reproducible gate or deny-rule defect | Host hook payloads, fail-closed behavior, and the distinction between mechanical enforcement and the working convention | `plugins/nightshift/hooks/`, `plugins/nightshift/hooks/windows/hardhat.ps1`, `plugins/nightshift/hooks/windows/clock-out-gate.ps1`, `tests/clock-out-gate.bats`, `tests/hardhat.bats`, `tests/windows-hardhat.bats`, `tests/codex/`, `tests/process-lease.bats` | `bats tests/clock-out-gate.bats tests/hardhat.bats tests/windows-hardhat.bats tests/codex/gate.bats tests/codex/hardhat.bats tests/process-lease.bats`, then `bats tests/` and `git ls-files '*.sh' \| xargs shellcheck -x` | Check [open bugs](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3Abug); if the queue is empty, open an issue with blocked-stop and permitted-stop evidence |
| **Platform support** | Extend the verified matrix, or reproduce an unsupported boundary before designing a fix | The target OS/container, native shell constraints, scheduling, paths, process evidence, and filesystem semantics | `plugins/nightshift/runtime/`, `plugins/nightshift/hooks/`, `tests/windows/`, `tests/environments/`, [Native Windows](windows.md), [Remote environments](remote-environments.md) | Run the platform-native suite and receipt probe, then preserve the exact supported and refused boundary in docs; also run `bats -r tests/`, shellcheck, `tests/coverage.sh`, and strict plugin validation | Open [Linux](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22platform%3A+linux%22), [Windows](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22platform%3A+windows%22), and [container](https://github.com/orwa-mahmoud/nightshift/issues?q=is%3Aissue+is%3Aopen+label%3A%22platform%3A+containers%22) work |
| **Run receipts** | Report one documented public-repository shift, including what failed | A run you can disclose and permanent links to its commits or PR | [`examples/bad-night-template.md`](../examples/bad-night-template.md) or an issue comment | `bats tests/bad-night-template.bats`, check every link, and remove private identifiers | [#22](https://github.com/orwa-mahmoud/nightshift/issues/22) |

## The easiest code-free path

A catalog entry is two new files and does not change shared hooks:

```text
plugins/nightshift/skills/nightshift/references/compose/shifts/<your-shift>.md
tests/shifts/<your-shift>.bats
```

Read the complete
[`catalog-recipe.md`](../plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md). It
defines the required ending, discovery method, definition of done, refusals, verification, and
supported stacks.

## Before opening a pull request

1. Confirm the issue or proposal agrees with the change.
2. Run the focused checks from the map.
3. Run the repository-wide checks required by
   [`CONTRIBUTING.md`](../CONTRIBUTING.md#checks) when the change can affect shared behavior.
4. Keep the pull request to one concern and report the exact commands and results.
5. Do not edit release manifests or `CHANGELOG.md`; Release Please owns them.
