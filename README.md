<div align="center">

# <img src="plugins/nightshift/assets/nightshift-logo.png" alt="" width="56" align="absmiddle"> nightshift

Nightshift is a plugin for **Claude Code, Codex, and Cursor**.

[![OpenAI Plugin Directory](https://img.shields.io/badge/OpenAI-Plugin_Directory-111111)](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
[![HOL Guard](https://img.shields.io/endpoint?url=https%3A%2F%2Fhol.org%2Fapi%2Fregistry%2Fbadges%2Fplugin%3Fslug%3Dorwa-mahmoud%252Fnightshift%26metric%3Dtrust)](https://hol.org/registry/plugins/orwa-mahmoud%2Fnightshift)

<a href="https://trendshift.io/repositories/95784"><img src="https://trendshift.io/api/badge/trendshift/repositories/95784/daily?language=Shell" alt="Trendshift #10 Repository of the Day in Shell" width="250" height="55"></a>

</div>

<table>
<tr>
<td width="33%" valign="top">
<p align="center"><strong><a href="#plan">Plan</a></strong></p>
<p>Take your plan further. Before the first write, bring the <strong>hard questions</strong> into the <strong>plan room</strong>. <strong>Compare approaches</strong>, <strong>set the boundaries</strong>, and <strong>choose the evidence</strong> for each task. Record decisions and a <strong>clear definition of done</strong> so your agent carries the agreed plan into execution.</p>
</td>
<td width="33%" valign="top">
<p align="center"><strong><a href="#execute">Execute</a></strong></p>
<p>Step away while Nightshift keeps your agent on the job. You choose when to start. It <strong>keeps your agent working</strong> through the <strong>punch list</strong> until <strong>every item is checked off</strong>. Decisions don’t block progress. The agent picks a default answer and records it in the <strong>parking lot</strong> for you to review.</p>
</td>
<td width="33%" valign="top">
<p align="center"><strong><a href="#review">Review</a></strong></p>
<p>Get reviewable results, not a marathon chat. <strong>Each item gets its own receipt.</strong> See what the agent <strong>delivered</strong>, what it <strong>tried and rejected</strong>, and which <strong>checks ran</strong>, alongside <strong>evidence</strong>, <strong>duration</strong>, and <strong>token usage</strong>. Decisions come back with <strong>the default chosen and why</strong>.</p>
</td>
</tr>
</table>

[![Nine finished items with receipts, working time, and measured token usage](docs/assets/finished-shift-receipts.png)](docs/assets/finished-shift-receipts.png)

## Shipped with Nightshift

**Nightshift built Nightshift.** Its initial shift produced the plugin’s clock-out gate, hooks, and commands. The build record pairs the original punch list with the commits. A later Codex shift completed **11 maintenance items** on one branch, with **one commit per item**, and shipped in **v0.9.2**. [Original build and commits](examples/self-build.md) · [Maintenance receipts](examples/codex-hardening-shift.md) · [Merged PR #53](https://github.com/orwa-mahmoud/nightshift/pull/53)

**Two agents worked the same plan.** When the Claude Code session ran out of allowance, the maintainer stopped it. **Ten minutes later**, Cursor resumed on the same branch with the same punch list. The shift spanned **45 elapsed hours**. After review and further fixes, the maintainer merged **67 commits** and closed **57 issues**. [Handoff timeline](examples/adapttable-continuity.md) · [Merged PR #353](https://github.com/orwa-mahmoud/adapttable/pull/353)

For a smaller run, follow the **nine-item shift** that shipped inline editing and row grouping in **AdaptTable v1.2.0**. [Overnight punch list](examples/adapttable-overnight.md) · [Merged PR #75](https://github.com/orwa-mahmoud/adapttable/pull/75)

## Install

It installs as a **native plugin**, with no separate app, service, or API key. It runs on **macOS, Linux, and Windows**, in any project on your disk: a **Git repository**, or a plain folder for work that isn't code, such as a research report.

### Claude Code

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift@nightshift
```

### Codex

```sh
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Then review and trust its hooks, with `/hooks` in the CLI or, in the Codex app, the **Review hooks** button (the hook icon in the message box) or **Settings → Hooks**.

### Cursor

Open **Customize → Add → From GitHub Repository**, paste `https://github.com/orwa-mahmoud/nightshift`, select **Import**, and install Nightshift from the imported marketplace.

[Installation and host support](docs/install.md#install)

## Your first shift

Open the project you want to work on and run `/nightshift:setup`. Answer a few questions to set your preferences. [What Setup asks](docs/setup.md)

### Plan

Enter the **plan room** with `/nightshift:plan`, continue one of your **plans** or start a new one with a name, and describe what you want **in your own words**: a feature, a refactor, a bug, a whole backlog, or GitHub issues you stage with `/nightshift:import-issues`. Your project code stays **read-only** while the room is open, so the agent can't jump into implementing while you're still brainstorming. It reads the relevant code, tests, and history, explains what **each approach buys you**, and turns what you agree on into **punch list** items.

When you enter the room, the agent asks you once, up front:

- **Which plan:** continue one of your plans, or start a new one and name it.
- **How to brainstorm:** whether you want an **edge-case pass** for the cases each item can meet, a **pre-mortem** on how the plan could fail, an **ordering and risk check**, or **research** on the open questions.
- **Whether to suggest evidence:** proof that fits each item, picked from the **evidence catalog**, such as **screenshots at named widths** for a layout change, **before-and-after figures** for a speed-up, or **a sample request and the schema diff** for an API change. If you want it, you also choose whether a missing file is **hard-checked**, holding the item open until it exists, **only reported** on the receipt, or not checked at all.

Pick any or none. What you pick is applied as each item takes shape; with none, these never come up again unless you ask. Every suggestion is yours to keep, edit, or drop. As the list nears completion, Nightshift estimates **working time** and **token usage** from your past receipts. For an item likely to get stuck, the agent offers a **budget** in working time, tokens, or both, and says why. At the **soft limit** the agent is told to finish the item. At the **hard limit** it can only commit the **work in progress**, write the **receipt**, and move on to the next item. [Item budgets](docs/item-budgets.md)

Each plan is its own file, a complete punch list with its own contract and checks, so plans never mix. Each item is written to it as soon as you agree with it, and edited in place as the discussion moves. The **plan record** keeps **decisions, rejected options, and open questions**, so a new day or a closed tab picks up exactly where you stopped. [Inside the plan room](docs/plan-room.md)

### Execute

When you’re ready, run `/nightshift:start`. If the punch list has open items, the agent works those. If it is empty, Start offers your **plans** by name, and any staged items, and runs the one you pick. Prepare several plans, then run them one after another.

A shift runs one of **two ways**:

- **Work a list.** The agent takes the agreed items one by one and the shift ends at the last tick. A deadline is optional and only caps it.
- **Work toward a goal until quitting time.** Run `/nightshift:hunt`, give it a goal and the hours, and the agent keeps working in complete units until the deadline. At quitting time it finishes the unit in hand and starts no new one.

You don't need a **backlog** to start. Nightshift ships **32 ready-made shifts**: **four open-ended** ones, coverage hunt, defect hunt, product evolution, and your own objective, plus **28 finite** ones such as dependency upgrades, vulnerability sweeps, flaky-test repair, accessibility repair, documentation drift, and release readiness. Pick entries yourself or let **Hunt** choose them for your goal, and review the composed shift first or run it directly. `/nightshift:quality` surveys tests, accessibility, dependencies, and other **quality debt**, and you choose what to **fix now** or **draft for later**. [Ready-made shifts](docs/shift-modes.md#ready-made-shifts) · [Shift modes](docs/shift-modes.md)

While the shift runs, `/nightshift:status` shows the open item, the deadline, parked decisions, snags, and whether the watchman is on duty. Decisions go in the **parking lot** with the default the agent used and its reason. Use `/nightshift:stop` to pause and keep unfinished items open. `/nightshift:doctor` diagnoses the workspace and changes nothing. [Preparing for an unattended shift](docs/first-night-checklist.md)

### Review

Open the **morning receipt** to see how the shift ended, which changes to inspect first, which **decisions** need your attention, and what the whole shift cost: **working time**, **paused time**, and **tokens**. Follow an item to see what the agent **delivered**, what it **tried and rejected**, which **checks ran**, any checks it couldn’t run, and the **time and tokens that item took**, session by session. Both come from the host’s own records, never the agent’s estimate. [Example receipts](examples/receipts.md) · [Reading the morning receipt](docs/morning-receipt.md) · [How usage is measured](docs/receipts.md#token-usage-is-measured-by-the-runtime)

You choose the **evidence** and judge the result. For a layout change, open the screenshot and check the interaction yourself. For a performance change, compare the before-and-after measurements. If you require a named file, the **gate** checks that it exists. [Evidence options](docs/evidence.md)

Run `/nightshift:archive` to file the shift into its own folder, with its **receipts** and **evidence**. Open items and unanswered decisions stay in the live files for the next shift. [Archive and continue](docs/archive.md)

## What else Nightshift handles

| What you want to do | How Nightshift handles it |
| --- | --- |
| [Finish an agreed list](docs/how-it-works.md#the-work-contract) | The **punch list** lives on disk, so it survives **compaction** and new sessions. If the agent tries to stop with work still open, the **clock-out gate** sends it back to the list. |
| [Switch agents mid-shift](examples/adapttable-continuity.md) | The whole shift lives on disk, so moving between **Claude Code, Codex, and Cursor**, in any order, is just `/nightshift:stop` in one and `/nightshift:start` in the other. The new agent reads the **punch list**, **receipts**, **parked decisions**, **snag log**, and **shift log** and carries on, with nothing to re-explain. |
| [Keep the agent inside your rules](docs/how-it-works.md#mechanical-gates-and-owner-rules) | Deny **commands**, **protected paths**, **secret patterns**, or commits under the wrong **identity**. Hooks enforce them in **every permission mode**, fully unattended included. |
| [Keep your checkout untouched](docs/knobs.md#shift-worktrees) | With `shift.isolation` set to `worktree`, each shift gets its own **worktree and branch**. Your checkout, index, and uncommitted edits stay as you left them. |
| [Recover an interrupted shift](docs/how-it-works.md#recovery) | A **watchman outside the session** monitors the shift and **resumes interrupted work**. If Claude’s API starts returning **500 errors overnight**, the watchman retries recovery and resumes the shift when the service responds again. **You can stay asleep.** It also handles crashes, stalls, and usage limits using your host’s recovery signals, carrying on from the **punch list and saved progress**. |
| [Start at a fixed time](docs/commands.md#start-at-a-fixed-time) | `/nightshift:schedule` checks that work is queued and that permissions won't stall a **headless run**, then prints the **launchd, cron, systemd, or Task Scheduler** entry. It registers nothing itself. |

## Make it yours

Write your own **receipt templates**, **morning summaries**, and **evidence instructions**, with the headings, wording, and layout you want. Add, replace, or remove **checks**. Create **shifts**, **evidence entries**, and **edge-case packs** for the way you work. The shipped templates are starting points you can change.

Open `/nightshift:customize` to see **every setting, template, and catalog entry** on one screen, or edit the files directly. Keep a workflow with one project or put it in your **personal catalog** to use across repositories. An entry with the same name as a shipped one replaces it. [Settings and catalogs](docs/knobs.md#catalogs) · [Create your own catalog entry](docs/add-to-a-catalog.md#only-for-you)

## Contributing

- **Share a workflow that works for you.** Turn a recurring task into a shift others can use, whether it works on a Git repository or a folder of research, documents, or other deliverables. Share the idea or contribute the Markdown entry. [Shift ideas and contributions · #21](https://github.com/orwa-mahmoud/nightshift/issues/21)
- **Share how you judge the work.** A screenshot, benchmark, recording, or another artifact can help someone review a change. Contribute your way of capturing it as an evidence entry. [Evidence ideas and contributions · #219](https://github.com/orwa-mahmoud/nightshift/issues/219)
- **Share your checks and edge cases.** Bring the commands that catch problems in your stack, or the cases you always test before shipping. Add a gate stack or an edge-case pack. [Checks and edge cases · #220](https://github.com/orwa-mahmoud/nightshift/issues/220)
- **Share what your shift delivered.** Link the requested work, the result, and what you found in review. Successful runs, interrupted shifts, and things you had to fix all help. [Run receipts · #22](https://github.com/orwa-mahmoud/nightshift/issues/22)
- **Build an improvement to Nightshift.** Have an idea that makes Nightshift more useful? Build it and open a pull request, or propose the enhancement for discussion. [Contribute a change](CONTRIBUTING.md) · [Propose an enhancement](https://github.com/orwa-mahmoud/nightshift/issues/new?template=feature_request.yml)

[Contribution guide](CONTRIBUTING.md) · [Where to contribute code](docs/contribution-map.md)

If Nightshift is useful to you, [star the repository](https://github.com/orwa-mahmoud/nightshift) to help other developers discover it.

## Documentation

[Documentation index](docs/README.md#documentation) · [Website](https://nightshift.orwamahmoud.com/) · [Command reference](docs/commands.md) · [Troubleshooting](docs/troubleshooting.md) · [Remote SSH and devcontainers](docs/remote-environments.md)

## License

[MIT](LICENSE) © [Orwa Mahmoud](https://orwamahmoud.com)
