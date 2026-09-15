# Contributing to Nightshift

Thanks for looking under the hood. The plugin is deliberately bounded — a punch-list contract,
native enforcement and recovery on disk, transparent skills, and a ledger that records what was
measured — so contributions should preserve explicit authority, local ownership, reversibility,
cross-host alignment, and honest evidence.

The bounded core: on-disk work contract, stop-gate hook, watchman recovery, and skills that hold an
agent to both. Contributions must not weaken owner gates, invent silent policy, or add mandatory
hosted services, accounts, or connectors to the MIT core.

Not sure where to start? Use the
[contribution map](docs/contribution-map.md) to choose catalog, documentation, testing, runtime,
recovery, hook, platform, or public-run work with the relevant files and checks.

## Ground rules

- **Open an issue first** for anything beyond a typo or small fix. The gate's
  behaviour is a contract; changes to it need discussion before code.
- **One concern per PR.** A hook fix and a docs fix are two PRs.
- **Shell must stay portable.** Hooks run under bash, and must work on macOS's
  bash 3.2 — no bashisms newer than 3.2, no GNU-only flags (`xargs -d`, `sed -i`
  without a suffix, etc.). Where a GNU tool has no portable equivalent, try it
  and fall back to the BSD form, as the deadline parser does.
- **PowerShell must stay portable.** Native Windows hooks and helpers run under
  Windows PowerShell 5.1 and PowerShell 7. Avoid syntax and APIs that exist on
  only one of those runtimes.
- **Test both gate outcomes.** If your change touches the stop-gate, include the
  transcript of an actual blocked stop and an actual permitted one in the PR
  description. The tests in `tests/` must pass.

## AI-assisted contributions

AI-assisted contributions are welcome. Contributors remain responsible for the
correctness, security, licensing, testing, and quality of everything they submit.
The same review standards apply regardless of which tools were used.

## Setup

```bash
git clone https://github.com/orwa-mahmoud/nightshift.git
# install as a local plugin, then run Nightshift: Setup in Codex or
# /nightshift:setup in Claude Code inside a scratch project
```

## Checks

```bash
tests/run-parallel.sh                # full suite in parallel (default 6 shards; ~wall-clock of slowest shard)
tests/run-shard.sh 1 6               # one CI shard; use --list to print its files without running bats
bats -r tests/                       # serial full suite (same coverage, slower)
git ls-files '*.sh' | xargs shellcheck -x  # lint — the same set CI checks
tests/coverage.sh                    # line coverage via kcov (runs in docker on non-Linux)
claude plugin validate . --strict    # manifest + marketplace validation
evals/run.sh                         # catalog contract schema, case book, and size budgets
```

Shell must stay Python-free: the plugin ships no `.py` file, and `tests/armed-no-python-jq.bats`
holds that line together with an armed shift that has neither `jq` nor `python3` installed.

CI ([`ci.yaml`](.github/workflows/ci.yaml)) runs shellcheck, the bats suite, and plugin validation
when the matching trees change. A docs-only edit runs `tests/run-docs-contract.sh` instead of the
full shard matrix. A Release Please version bump validates manifests and skips Windows, remote, and
shards. Required job names still report, so merge is not left waiting. Bats runs as six parallel
shards on both Ubuntu and macOS (same partition as `tests/run-shard.sh`); the macOS job keeps the
system Bash 3.2 first on `PATH`. A `windows-native` job runs `tests/windows/run.ps1` under Windows
PowerShell 5.1 and PowerShell 7. A `remote-ssh` job crosses an ephemeral OpenSSH connection; a
`devcontainer` job starts the checked-in fixture. Both compare sanitized receipts — they do not
load an authenticated host session.

## Releasing

Nothing is published by merging your pull request. Version numbers and the changelog are not
yours to edit — [release-please](.github/workflows/release-please.yaml) writes both from commit
subjects, and holds them in a pull request titled `chore: release x.y.z` that it refreshes on
every merge. The maintainer merges that pull request when a release is due; that merge tags the
commit and publishes the notes.

What decides the version is the subject line of your commits, so write them to the
[Conventional Commits](https://www.conventionalcommits.org/) spec:

| Subject | Effect |
| --- | --- |
| `fix: …` | patch — `0.7.4` → `0.7.5` |
| `feat: …` | minor — `0.7.4` → `0.8.0` |
| `feat!: …`, or a `BREAKING CHANGE:` footer | major |
| `docs: …` `chore: …` `ci: …` `test: …` `refactor: …` | no release, no changelog entry |

Only `fix:` and `feat:` reach the changelog, so a subject is user-facing text: say what the change
does for someone running a shift, not how it was implemented. Do not tag by hand, and do not edit
`plugins/nightshift/.claude-plugin/plugin.json` or `CHANGELOG.md` — a pull request that does will conflict with
the release it is trying to describe.

## What gets merged

Fixes that make the gate harder to fool, **new entries for the shift catalog**, and
docs that shorten the path to a first successful shift.

The [contribution map](docs/contribution-map.md) links current issues and gives each area an entry
path, prerequisite knowledge, likely files, and focused verification commands.

Shift catalog entries are the easiest way in: they are markdown, they touch no
hooks, and they grow the catalog without growing the product. Read
[`catalog-recipe.md`](plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md) first — an
entry must declare its ending, how it discovers work, its definition of done, what
it will never do, its verification, and the stacks it supports. Every catalog PR is
read by a human before merge: a plausible entry can still be a bad night on someone
else's repository, and no automated check catches that.

Nightshift is an augmentation layer in the Claude Code, Codex, and Cursor
ecosystems. It integrates through each host's native plugins, skills, and hooks —
without introducing a separate agent runtime, proxy, or installation channel.
Shared behaviour should stay aligned across all three hosts; host-specific code
should be a thin integration, not a generic adapter layer. Changes that stand outside those
extension points are declined, however useful they sound: dashboards, proxies,
and second install channels such as npm or Homebrew. The exceptions are OS
scheduling and recovery code that exist only to keep an *inside* promise when no
live session can act.

## License

MIT — by contributing you agree your work ships under it.
