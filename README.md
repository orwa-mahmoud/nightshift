<div align="center">

# <img src="plugins/nightshift/assets/nightshift-logo.png" alt="" width="56" align="absmiddle"> nightshift

[![OpenAI Plugin Directory](https://img.shields.io/badge/OpenAI-Plugin_Directory-111111)](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
[![Website](https://img.shields.io/badge/Website-nightshift-2563eb)](https://nightshift.orwamahmoud.com/)
[![HOL Guard](https://img.shields.io/endpoint?url=https%3A%2F%2Fhol.org%2Fapi%2Fregistry%2Fbadges%2Fplugin%3Fslug%3Dorwa-mahmoud%252Fnightshift%26metric%3Dtrust)](https://hol.org/registry/plugins/orwa-mahmoud%2Fnightshift)

**Give the agent a shift. Come back to work you can review.**

</div>

Nightshift gives [Claude Code](https://claude.com/claude-code),
[OpenAI Codex](https://openai.com/codex/), and [Cursor](https://cursor.com) a durable work contract
for long coding runs. Plan the work with the agent first, then bring a task list, choose a
ready-made shift, or give your agent an objective and hours to work. A clock-out gate holds
unfinished work, each item can carry the evidence you ask for and a time or token budget, progress
survives on disk, and a watchman can recover failed sessions. Review the results, per-item token
usage and time where available, then archive the shift with its evidence intact.

<div align="center">

**MIT licensed · macOS, Linux, Windows · No separate service or API key**

[Install](#install) · [First shift](#your-first-shift) · [Real runs](#the-morning) ·
[Why it exists](docs/why-nightshift.md#why-nightshift-exists) · [Documentation](docs/README.md#documentation) ·
[Website](https://nightshift.orwamahmoud.com/)

[![Why Nightshift exists: without Nightshift the agent promises to continue, then stops; with Nightshift the shift completes with per-item receipts](docs/assets/nightshift-before-after.png)](docs/why-nightshift.md#why-nightshift-exists)

</div>

| What you want | What Nightshift provides |
| --- | --- |
| **[Design the work before building it](docs/how-it-works.md#the-plan-room)** | A plan room that explores the code with you, offers a pre-mortem, an edge-case pass and an ordering check, sizes the plan from your past receipts, and builds nothing until you leave. |
| **[Finish the work you already planned](docs/how-it-works.md#the-work-contract)** | A persistent punch list, item-by-item verification, and a gate that rejects premature clock-out. |
| **[Put a few hours into the project](docs/shift-modes.md#shift-modes)** | Open-ended product evolution, coverage hunts, or your own objective, with an explicit deadline and a continuation record. |
| **[Start without writing a backlog](docs/shift-modes.md#choose-the-right-starting-point)** | Ready-made shifts through Hunt and Quality. Choose the work yourself or let the agent compose it; review first or run directly. |
| **[See proof, not just a tick](docs/receipts.md#evidence-a-reviewer-opens-first)** | An evidence line per item from a catalog of kinds, an optional file map in each receipt, and your choice of whether missing evidence holds the clock-out. |
| **[Keep each item in bounds](docs/knobs.md#item-budgets)** | Soft and hard limits per item in working time, tokens, or both. A hard limit turns the agent to wrap-up and closes the item as stopped. |
| **[Keep a long run moving](docs/how-it-works.md#recovery)** | Progress across compaction, parked decisions, deduplicated findings, and recovery under the host's supported signals. |
| **[See what the work consumed](docs/receipts.md#receipts-and-token-usage)** | Runtime-measured token usage and duration per item, with host-specific gaps clearly marked. |
| **[Review today and continue tomorrow](docs/archive.md#archive-and-continue)** | Live receipts, a morning receipt, and archived history that keeps unfinished work available for the next shift. |
| **[Make it yours](docs/knobs.md#catalogs)** | One customize screen for every setting, template and catalog entry, and your own evidence kinds, gate stacks, edge-case packs and ready shifts beside the shipped ones. |

**Real runs.** The [four-hour first night](examples/adapttable-overnight.md#example--an-overnight-run-on-a-production-library)
left nine focused items as reviewable commits. A later
[45-hour contract](examples/adapttable-continuity.md#flagship-example--one-contract-two-coding-agents-57-issues)
survived a host handoff and became a human-reviewed 67-commit pull request. These are documented
runs, not benchmarks.

## Why Nightshift

It started with eight requested changes and a screen saying the four hard ones deserved a
“focused session.” The agent had finished the easy work and left the rest for later.

Nightshift makes the remaining work explicit at every attempted stop. The list survives context
compaction, decisions go into a parking lot with a default, and a watchman can recover failed
sessions. The checks and your review still determine whether a completed item is good.
[Read the story and see the original screenshot →](docs/why-nightshift.md#why-nightshift-exists)

## Install

### Claude Code

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift
```

### Codex

```text
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Review and trust the plugin's hooks (`/hooks` in the CLI), then start a new conversation. The
[OpenAI Plugin Directory listing](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
is a skills-only edition for attended sessions and ChatGPT, without the clock-out gate, recovery or
usage accounting.

### Cursor

Open **Customize → Add → From GitHub Repository**, paste
`https://github.com/orwa-mahmoud/nightshift`, select **Import**, then install Nightshift from the
imported marketplace.

Open the project you want Nightshift to change: a Git repository or a persistent local folder. A
disposable ChatGPT scratch conversation cannot preserve project changes. macOS and Linux use the
bundled Bash runtime and native Windows uses bundled PowerShell.
[Install details](docs/install.md#install) covers skills.sh, Windows, WSL, remote environments and
each host's recovery limits.

## Your first shift

Start with one small task in a project you trust. Keep the first run attended and use the
[first-night safety checklist](docs/first-night-checklist.md#first-night-safety-checklist) before leaving a longer run alone.

| Action | Codex: ask Nightshift | Claude Code |
| --- | --- | --- |
| Set up | “Set up Nightshift in this project.” | `/nightshift:setup` |
| Plan before building | “Plan this with Nightshift.” | `/nightshift:plan` |
| Leave the plan room | Type `$nightshift:plan-exit` | `/nightshift:plan-exit` |
| Run for hours | “Improve this project for 5 hours.” | the same sentence, or `/nightshift:hunt` |
| Start | “Start the Nightshift shift.” | `/nightshift:start` |
| Check progress | “Show Nightshift status.” | `/nightshift:status` |
| Diagnose | “Diagnose this Nightshift workspace.” | `/nightshift:doctor` |
| Stop | “Stop the Nightshift shift.” | `/nightshift:stop` |
| Customize | “Customize Nightshift.” | `/nightshift:customize` |

1. **Set up.** Setup asks at most four questions: your checks, then every default on one screen.
   Or skip it: say *“improve this project for 5 hours”* and Nightshift sets the project up, picks
   the work from the catalog, and starts. With no hours it asks one question: how many hours.
2. **Plan or write the work.** Design it with the agent in the plan room, or write one item under
   `## Items` in `.nightshift/punch-list.md`:

   ```text
   - [ ] **1. Document how to run the tests.**
     - Find the test command configured in this repository.
     - Add it to the README with its prerequisites and the directory to run it from.
     - Verify: run the documented command and check that the instructions match it.
     - Commit: `docs: explain how to run the tests`
   ```

   The title names the result, the bullets bound the work, `Verify` states how to check it, and
   `Commit` names the local change. More in [the example punch list](examples/overnight-webapp.md#example--an-overnight-webapp-punch-list).
3. **Start.** Start checks the workspace and permissions, arms the shift, and works the list
   without another question. If it refuses, it names the repair.
4. **Review.** Read the morning receipt and each item's receipt, inspect the change, and push only
   when you decide to. A tick is the agent's completion claim, not independent proof of quality.

A persistent folder without Git works too: artifact mode completes each item through
artifact receipts under `.nightshift/receipts/`. The [vocabulary](docs/vocabulary.md#vocabulary) names every
working file, and [Evidence and receipts](docs/evidence-capabilities.md#reviewing-a-shift) says what
to review.

## The morning

[![The receipts index of a finished shift: nine ticked items, each with its tokens, working time and receipt](docs/assets/finished-shift-receipts.png)](docs/receipts.md#receipts-and-token-usage)

The [morning receipt](docs/morning-receipt.md#the-morning-receipt) says how the shift ended, what
verification ran, what was unavailable, and what needs you. The receipts index lists every item
with its state, tokens and time. Each item's receipt holds what was delivered, what was tried and
rejected, how it was verified, its evidence, and the files it changed; it updates during the work.
Then [archive the shift](docs/archive.md#archive-and-continue): finished items and handled records
move into dated history, while open work, unanswered decisions and the contract stay live for the
next shift.

The [real runs](examples/README.md#real-runs) library follows real shifts through their review,
with a template for reporting a bad night without hiding what happened.

## Two kinds of shift

- **A finite list.** Write the items yourself or approve work staged on the drafting table, then
  Start works that list. It ends at the last tick; an optional deadline caps the run.
- **A goal with a clock.** Hunt composes work from the ready-made catalog: defect repair,
  dependency upgrades, release readiness, documentation, accessibility, research and more.
  Product evolution and coverage hunts continue until quitting time; an owner walkthrough keeps
  your own objective verbatim and works it for the hours you set.

Quality composes a shift from the project's quality debt, and Import issues stages named GitHub
issues without searching or writing back. Plan with one model and execute with another: the
on-disk contract carries the work. Schedule prints the operating-system entry to start a shift at
a fixed time. [Shift modes](docs/shift-modes.md#shift-modes) covers every combination.

## Before you leave it alone

- **Choose permissions and checks.** An unattended run cannot approve prompts. Verification can
  run per item, at the end, on a custom cadence, or never; the receipts state what actually ran.
- **Stop always wins.** Ask Nightshift to stop or use the [offline stop command](docs/commands.md#command-reference).
  Unfinished boxes stay open.
- **Bound retries.** A stalled finite shift remains held by default. Set a deadline, a stall limit
  or [item budgets](docs/knobs.md#item-budgets) when you need a cost boundary.
- **Check your host's recovery limits.** The watchman requires positive failure evidence, and
  [recovery has host-specific boundaries](docs/how-it-works.md#recovery). The recovered
  headless worker can continue without you watching it.
- **Keep your checkout free.** Set `shift.isolation` to `worktree` and each shift works in its own
  git worktree and branch ([shift worktrees](docs/knobs.md#shift-worktrees)).
- **Review before publishing.** Commits stay local unless the contract authorizes otherwise.
  Optional guards are hardening, not a sandbox ([owner knobs](docs/knobs.md#owner-knobs)).

The recovery signals, process lease, host differences and limits are in
[How Nightshift works](docs/how-it-works.md#how-nightshift-works).

## Documentation

Use the [documentation index](docs/README.md#documentation) for the full reference, grouped by task.

- [Install details](docs/install.md#install) — every host, skills.sh, and platforms.
- [Vocabulary](docs/vocabulary.md#vocabulary) — the names of the working files and mechanisms.
- [How Nightshift works](docs/how-it-works.md#how-nightshift-works) — lifecycle, plan room, policy, recovery, and limits.
- [Shift modes](docs/shift-modes.md#shift-modes) — choose and compose the work.
- [Command reference](docs/commands.md#command-reference) — skills, scheduling, and offline controls.
- [Owner knobs](docs/knobs.md#owner-knobs) — permissions, verification, budgets, catalogs, receipts, and retention.
- [Receipts and token usage](docs/receipts.md#receipts-and-token-usage) — live progress, evidence, per-item measurements, and host limits.
- [Archive and continue](docs/archive.md#archive-and-continue) — preserve finished shifts and carry open work forward.
- [Troubleshooting](docs/troubleshooting.md#troubleshooting) — diagnose before repairing.

## Contributing

Catalog entries are a focused starting point: one Markdown file per entry, with no code.
[Add to a catalog](docs/add-to-a-catalog.md#add-to-a-catalog) walks through it. Human and
AI-assisted contributions are welcome. Use the [contribution map](docs/contribution-map.md#choose-your-contribution) to
choose an area; verification and the release process are in [CONTRIBUTING.md](CONTRIBUTING.md#contributing-to-nightshift).

If Nightshift is useful to you, [star the repository](https://github.com/orwa-mahmoud/nightshift)
to help other developers discover it.

## License

[MIT](LICENSE) © [Orwa Mahmoud](https://orwamahmoud.com)
