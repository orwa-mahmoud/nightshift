# Contributing to Nightshift

Contributions are welcome across planning, execution, receipts, customization, recovery, and
supported hosts. Share something you use, improve a workflow, or help another developer get a
successful first shift.

## Choose a contribution

| Bring | Start here |
| --- | --- |
| A recurring workflow for code, research, documents, or other deliverables | [Shift catalog · #21](https://github.com/orwa-mahmoud/nightshift/issues/21) |
| A way to capture evidence that helps you review work | [Evidence entries · #219](https://github.com/orwa-mahmoud/nightshift/issues/219) |
| Project checks or edge cases that catch real defects | [Gate stacks and edge-case packs · #220](https://github.com/orwa-mahmoud/nightshift/issues/220) |
| A shift and what you found in review, including an interrupted or unsuccessful run | [Run receipts · #22](https://github.com/orwa-mahmoud/nightshift/issues/22) |
| An improvement to Nightshift | [Propose an enhancement](https://github.com/orwa-mahmoud/nightshift/issues/new?template=feature_request.yml) |

Catalog entries are Markdown files. Use a shipped template or write your own headings and layout.
[Add to a catalog](docs/add-to-a-catalog.md) describes the fields each catalog reads.
For code contributions, the [contribution map](docs/contribution-map.md) identifies the relevant
files and checks.

## Working on a change

- **Use an existing issue or ongoing thread** when it fits. Open an issue for a new feature or
  substantial behavior change before implementing it. Typos and small fixes can go straight to a PR.
- **Keep one concern per PR.** Include the implementation, tests, and documentation needed for
  that change together.
- **Shell must stay portable.** Hooks run under bash, and must work on macOS's
  bash 3.2 — no bashisms newer than 3.2, no GNU-only flags (`xargs -d`, `sed -i`
  without a suffix, etc.). Where a GNU tool has no portable equivalent, try it
  and fall back to the BSD form, as the deadline parser does.
- **Assertions must fail on bash 3.2.** In a Bats test, end every `[[ ]]`,
  `(( ))` and `!` statement with `|| false` (or a `|| { ...; return 1; }`
  group): bash 3.2 ignores those failures anywhere but a test's last line, and
  no bash fails a test on `!`. `tests/bats-assertions.bats` rejects the bare forms.
- **PowerShell must stay portable.** Native Windows hooks and helpers run under
  Windows PowerShell 5.1 and PowerShell 7. Avoid syntax and APIs that exist on
  only one of those runtimes.
- **Test both gate outcomes.** For a stop-gate change, demonstrate a blocked stop and a permitted
  stop. Include the focused test results or sanitized reproduction output in the PR.

## AI-assisted contributions

AI-assisted contributions are welcome. Contributors remain responsible for the
correctness, security, licensing, testing, and quality of everything they submit.
The same review standards apply regardless of which tools were used.

## Setup

```bash
git clone https://github.com/orwa-mahmoud/nightshift.git
cd nightshift
```

Run the repository checks from this checkout. Exercise plugin changes in a separate scratch
project using the checkout's plugin.

For Claude Code, start a session from the scratch project with the absolute path to the plugin:

```sh
claude --plugin-dir /absolute/path/to/nightshift/plugins/nightshift
```

For Codex, register the checkout as a local marketplace, then install its plugin:

```sh
codex plugin marketplace add /absolute/path/to/nightshift
codex plugin add nightshift@nightshift
```

Review and trust the hooks, then open a new conversation in the scratch project. Enable one
Nightshift copy for the test and run `/nightshift:setup`.
[Installation and host setup](docs/install.md) covers hook trust and platform details.

## Checks

Run the tests covering the behavior you changed and report the command and result in your PR.
For example, a clock-out gate change starts with `bats tests/clock-out-gate.bats`. Run the matching
Windows checks when shared behavior changes. For prose changes, check links, paths, and commands.

The commands below cover broader verification when the change needs it. Coverage is a separate run.

| Command | What it checks |
| --- | --- |
| `tests/run-parallel.sh` | The full suite in parallel, 6 shards by default; takes about as long as the slowest shard. |
| `tests/run-shard.sh 1 6` | One CI shard. `--list` prints its files without running Bats. |
| `bats -r tests/` | The full suite, serially: same coverage, slower. |
| `tests/lint-shell.sh` | Shell lint, the same set CI checks. |
| `tests/coverage.sh` | Line coverage through kcov, in Docker on non-Linux hosts. |
| `claude plugin validate . --strict` | The manifests and the marketplace. |
| `evals/run.sh` | The catalog contract schema, the case book, and the size budgets. |

Shell must stay Python-free: the plugin ships no `.py` file, and `tests/armed-no-python-jq.bats`
holds that line together with an armed shift that has neither `jq` nor `python3` installed.

CI selects jobs from the paths changed. Documentation uses the docs contract checks; runtime
changes run the Bats suite on Ubuntu and macOS, native Windows checks, and the relevant lint and
plugin validation. macOS uses Bash 3.2; Windows runs PowerShell 5.1 and 7. Remote SSH and
devcontainer jobs exercise their respective fixtures. [CI workflow](.github/workflows/ci.yaml)

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

## Project fit

Nightshift integrates through the native plugins, skills, and hooks of Claude Code, Codex, and
Cursor. Keep implementations in those extension points, with shared behavior aligned across hosts.
OS scheduling and recovery run outside the session so a shift can start or resume when the agent
is absent.

Preserve the owner's chosen rules, local state, and control over starting and stopping work.
Make new policy explicit and configurable. The MIT plugin runs locally with the coding agent
the owner selects. Keep additional hosted services, accounts, and connectors optional.

## License

MIT — by contributing you agree your work ships under it.
