# nightshift

[![OpenAI Plugin Directory](https://img.shields.io/badge/OpenAI-Plugin_Directory-111111)](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
[![Website](https://img.shields.io/badge/Website-nightshift-2563eb)](https://nightshift.orwamahmoud.com/)
[![HOL Guard](https://img.shields.io/endpoint?url=https%3A%2F%2Fhol.org%2Fapi%2Fregistry%2Fbadges%2Fplugin%3Fslug%3Dorwa-mahmoud%252Fnightshift%26metric%3Dtrust)](https://hol.org/go/guard/orwa-mahmoud-uae?dest=%2Fguard%2Fbilling%3Fpromo%3DGUARD20-ORWA-MAHMOUD-UAE%23upgrade&link_id=9a8e4449-def8-4c8d-9ba9-a4eac24754c3&utm_source=insights_share&utm_medium=affiliate_cta&utm_campaign=share20)

**Give the agent a shift. Come back to work you can review.**

Nightshift gives [Claude Code](https://claude.com/claude-code),
[OpenAI Codex](https://openai.com/codex/), and [Cursor](https://cursor.com) a durable work contract
for long coding runs. Bring a task list, choose a ready-made shift, or give your agent an objective
and hours to work. A clock-out gate holds unfinished work, progress survives on disk, and a watchman
can recover failed sessions. Review the results, per-item token usage and time where available,
then archive the shift with its evidence intact.

**MIT licensed · macOS, Linux, Windows · No separate service or API key**

[Install](#install) · [First shift](#your-first-shift) · [Real runs](#the-morning) ·
[Why it exists](docs/why-nightshift.md#why-nightshift-exists) · [Documentation](docs/README.md#documentation) ·
[Website](https://nightshift.orwamahmoud.com/)

| What you want | What Nightshift provides |
| --- | --- |
| **Finish the work you already planned** | A persistent punch list, item-by-item verification, and a gate that rejects premature clock-out. |
| **Put a few hours into the project** | Open-ended product evolution, coverage hunts, or your own objective, with an explicit deadline and a continuation record. |
| **Start without writing a backlog** | Ready-made shifts through Hunt and Quality. Choose the work yourself or let the agent compose it; review first or run directly. |
| **Keep a long run moving** | Progress across compaction, parked decisions, deduplicated findings, and recovery under the host's supported signals. |
| **See what the work consumed** | Runtime-measured token usage and duration per item, with host-specific gaps clearly marked. |
| **Review today and continue tomorrow** | Live receipts, a morning receipt, and archived history that keeps unfinished work available for the next shift. |

[Choose a shift](#two-kinds-of-shift) · [Receipts and token usage](docs/receipts.md#receipts-and-token-usage) ·
[Archive and continue](docs/archive.md#archive-and-continue)

The [four-hour first night](examples/adapttable-overnight.md#example--an-overnight-run-on-a-production-library) left nine focused items as reviewable
commits. A later [45-hour contract](examples/adapttable-continuity.md#flagship-example--one-contract-two-coding-agents-57-issues) survived a host handoff and
became a human-reviewed 67-commit pull request. These are documented runs, not benchmarks.

## Why Nightshift

It started with eight requested changes and a screen saying the four hard ones deserved a
“focused session.” The agent had finished the easy work and left the rest for later.

Nightshift makes the remaining work explicit at every attempted stop. The list survives context
compaction, decisions go into a parking lot with a default, and a watchman can recover failed
sessions. The checks and your review still determine whether a completed item is good.
[Read the story and see the original screenshot →](docs/why-nightshift.md#why-nightshift-exists)

## Install

### Codex and ChatGPT

[Install Nightshift from the official OpenAI Plugin Directory](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe).

For local Codex development, install the same package from its marketplace:

```text
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Open the project you want Nightshift to change in Codex, or connect Codex to its GitHub repository.
A Git repository or a persistent local folder works. A disposable ChatGPT scratch conversation
cannot preserve project changes, so Setup redirects you to Codex before writing run state.

### Claude Code

Run inside Claude Code:

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift
```

### Cursor

Open **Customize → Add → From GitHub Repository**, paste
`https://github.com/orwa-mahmoud/nightshift`, choose a scope, and select **Import**.
Then select Nightshift from the imported marketplace to install it.
The [Cursor Directory listing](https://cursor.directory/plugins/nightshift) is for discovery;
installation happens inside Cursor. Read the host-specific
[recovery and CLI limitations](docs/how-it-works.md#recovery) before starting a shift.

### Platforms

macOS and Linux use the bundled Bash runtime. Native Windows uses bundled PowerShell, with no
Git Bash or WSL required. For WSL, keep the host, plugin, repository, and watchman in one Linux
distribution. See [Native Windows](docs/windows.md#native-windows) and
[Remote environments](docs/remote-environments.md#remote-ssh-and-devcontainers) for platform details.

<a id="run-a-first-shift"></a>

## Your first shift

Start with one small task in a project you trust. Keep the first run attended and use the
[first-night safety checklist](docs/first-night-checklist.md#first-night-safety-checklist) before leaving a longer run alone.

| Action | Codex: ask Nightshift | Claude Code |
| --- | --- | --- |
| Set up | “Set up Nightshift in this project.” | `/nightshift:setup` |
| Start | “Start the Nightshift shift.” | `/nightshift:start` |
| Check progress | “Show Nightshift status.” | `/nightshift:status` |
| Diagnose | “Diagnose this Nightshift workspace.” | `/nightshift:doctor` |
| Stop | “Stop the Nightshift shift.” | `/nightshift:stop` |

1. **Set up.** Review the proposed checks and permissions. Setup asks before applying them.
2. **Write one item** under `## Items` in `.nightshift/punch-list.md`. For a repository that
   already has a test runner, a small first task could be:

   ```text
   - [ ] **1. Document how to run the tests.**
     - Find the test command configured in this repository.
     - Add it to the README with its prerequisites and the directory to run it from.
     - Verify: run the documented command and check that the instructions match it.
     - Commit: `docs: explain how to run the tests`
   ```

   Use an outcome that matters to your project. The title names the result, the bullets bound
   the work, `Verify` states how to check it, and `Commit` names the local change. More filled
   examples are in [the example punch list](examples/overnight-webapp.md#example--an-overnight-webapp-punch-list).
3. **Start.** With work queued, Start checks the workspace and permissions, then arms the shift
   and works the list without another question. If it refuses, it names the repair. An empty
   list offers staged work instead of silently starting something new.
4. **Review.** Inspect the change, the checks that ran, and the shift report. Push only when you
   decide to. If progress looks wrong, Doctor reports the workspace state without changing it;
   follow [Troubleshooting](docs/troubleshooting.md#troubleshooting).

The **punch list** holds the work. **Gates** are the project checks, run on the verification
cadence you choose. The **parking lot** records decisions and defaults; the **shift log** records
progress and problems. A tick is the agent's completion claim, not independent proof of quality.

A persistent folder without Git works too: artifact mode completes an item through artifact receipts
under `.nightshift/receipts/`. Source and checkpoint receipts stay local. See
[Evidence and receipts](docs/evidence-capabilities.md#reviewing-a-shift) for what to review.

## The morning

Start with the [morning receipt](docs/morning-receipt.md#the-morning-receipt): how the shift ended, what verification
ran, what was unavailable or disabled, and what needs your attention. Then review:

- **The diff or output files** — the work you will accept, revise, or reject.
- **The shift report** — one section per item with results, verification, and output locations.
  It updates during the work, so you can inspect a long-running item before it finishes.
- **Parked decisions and snags** — defaults to accept or reverse, and unresolved findings to address.

### Token usage and time, per item

The runtime adds token usage and duration from host records to each completed item's report.
Input, output, cache, and reasoning figures retain the host's counting rules; missing readings
stay explicit. Choose progress updates by time, tokens, either, or completion only. These control
reporting, not a spending limit. [Receipts and token usage](docs/receipts.md#receipts-and-token-usage) explains the
measurements and limits; the [example report](examples/receipts.md#receipts) shows them in context.

### Archive the shift, keep the next step

Ask Nightshift to archive the finished work (`/nightshift:archive` in Claude Code). Completed
items and handled records move into dated history; open work, unanswered decisions, and the
punch-list contract stay live. Reports keep working links to their evidence, and a history index
makes prior shifts easier to revisit. Enable automatic filing at clock-out if you want that part
handled too. Pruning old history is a separate, explicit retention choice.
[Archive and continue](docs/archive.md#archive-and-continue) explains what is filed and what the next shift inherits.

The [real runs](examples/README.md#real-runs) library follows real shifts through their review,
including a 45-hour contract that survived a host handoff and became a human-reviewed 67-commit
pull request. It also includes a template for reporting a bad night without hiding what happened.

## Two kinds of shift

- **A finite list.** Write the items yourself or approve work staged on the drafting table, then
  Start works that list. It ends at the last tick; an optional deadline caps the run.
- **A goal with a clock.** Hunt composes work from the ready-made catalog. Product evolution and
  coverage hunts continue until quitting time; a defect hunt can finish earlier when a complete
  pass finds no new defects. Each entry declares its ending.

Ask Hunt to select the work automatically, or choose catalog entries yourself. Independently,
choose to review the plan first or start immediately. For example, after Setup:

> Use Nightshift for four hours to improve this product's onboarding. Inspect the project,
> propose the work, and wait for my approval before starting.

Quality uses the same choices for tests, lint, dependencies, documentation, accessibility, and
other applicable quality debt. Named GitHub issues can be staged with Import issues, then
promoted into the punch list. Import issues searches nothing and writes nothing back to GitHub.
The four combinations and ready-to-use requests are in [Shift modes](docs/shift-modes.md#shift-modes).

### Ready-made work, with a contract

The [ready-shift catalog](plugins/nightshift/skills/nightshift/references/compose/shifts/) covers
work such as defect repair, dependency upgrades, release readiness, developer onboarding,
documentation, accessibility, SEO audits, and research synthesis. Each entry carries its own
discovery method, definition of done, verification, and ending. Hunt can combine compatible
entries under one budget; the **Maintainer night** preset follows onboarding, documentation drift,
CI warnings, and release readiness in order.

**Product evolution** studies the project and its users, records evidence, ranks opportunities,
and builds complete improvements until quitting time. Its opportunity map keeps completed work,
rejected paths, the exact next action, and remaining verification available across sessions.

**Owner walkthrough** keeps your own objective verbatim and works it in coherent units for the
hours you set. Choose it in Guided mode. It can finish early when the objective's acceptance
criteria are verified; product evolution and coverage hunts continue until their deadline.

You can also plan with one model and execute with another: the on-disk contract and continuation
records carry the work. [Cross-host continuity](docs/evidence-capabilities.md#cross-host-continuity)
explains the handoff and its limits.

To run later, Schedule prints the operating-system configuration and install command; it registers
nothing itself. The [command reference](docs/commands.md#start-it-at-a-fixed-time) includes a
terminal path that needs no live model session or remaining allowance.

## Before you leave it alone

- **Choose permissions and checks.** An unattended run cannot approve prompts. Verification can
  run per item, at the end, on a custom cadence, or never; the report states what actually ran.
  Configure optional guards through [Owner knobs](docs/knobs.md#owner-knobs). They are hardening, not a sandbox.
- **Stop always wins.** Ask Nightshift to stop or use the [offline stop command](docs/commands.md#command-reference).
  Unfinished boxes stay open; the terminal path needs no live model session.
- **Bound retries.** A stalled finite shift remains held by default. Set a deadline or an explicit
  stall limit when you need a cost boundary. Open-ended work always requires a deadline.
- **Check your host's recovery limits.** The watchman requires positive failure evidence and
  inherits the recorded permissions by default. Recovery and stale IDE views have
  [host-specific boundaries](docs/how-it-works.md#recovery). The recovered
  headless worker can continue without you watching it.
- **Review before publishing.** Commits stay local unless the contract authorizes otherwise.
  Ticks are self-reported; item checks and human review determine whether the work is good.

The recovery signals, process lease, host differences, and limits are in
[How Nightshift works](docs/how-it-works.md#how-nightshift-works). The
[why and cost of the workflow](docs/why-nightshift.md#why-nightshift-exists) explain the trade-offs behind the design.

## Documentation

Use the [documentation index](docs/README.md#documentation) for the full reference, grouped by task.

- [How Nightshift works](docs/how-it-works.md#how-nightshift-works) — lifecycle, policy, recovery, and limits.
- [Shift modes](docs/shift-modes.md#shift-modes) — choose and compose the work.
- [Command reference](docs/commands.md#command-reference) — skills, scheduling, and offline controls.
- [Owner knobs](docs/knobs.md#owner-knobs) — permissions, verification, reports, and retention.
- [Receipts and token usage](docs/receipts.md#receipts-and-token-usage) — live progress, per-item measurements, and host limits.
- [Archive and continue](docs/archive.md#archive-and-continue) — preserve finished shifts and carry open work forward.
- [Troubleshooting](docs/troubleshooting.md#troubleshooting) — diagnose before repairing.

## Contributing

Catalog entries are a focused starting point: one Markdown contract and its checks. Human and
AI-assisted contributions are welcome. Use the [contribution map](docs/contribution-map.md#choose-your-contribution) to
choose an area; verification and the release process are in [CONTRIBUTING.md](CONTRIBUTING.md#contributing-to-nightshift).

If Nightshift is useful to you, [star the repository](https://github.com/orwa-mahmoud/nightshift)
to help other developers discover it.

## License

[MIT](LICENSE) © [Orwa Mahmoud](https://orwamahmoud.com)
