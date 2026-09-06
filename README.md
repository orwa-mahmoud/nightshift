# nightshift

[![HOL Guard](https://img.shields.io/endpoint?url=https%3A%2F%2Fhol.org%2Fapi%2Fregistry%2Fbadges%2Fplugin%3Fslug%3Dorwa-mahmoud%252Fnightshift%26metric%3Dtrust)](https://hol.org/go/guard/orwa-mahmoud-uae?dest=%2Fguard%2Fbilling%3Fpromo%3DGUARD20-ORWA-MAHMOUD-UAE%23upgrade&link_id=9a8e4449-def8-4c8d-9ba9-a4eac24754c3&utm_source=insights_share&utm_medium=affiliate_cta&utm_campaign=share20)

Nightshift gives [Claude Code](https://claude.com/claude-code),
[OpenAI Codex](https://openai.com/codex/), and [Cursor](https://cursor.com) accountable,
time-bounded engineering shifts. Hand it your own punch list or let it research the product, rank
opportunities, and build the strongest complete improvements until quitting time. State stays on
disk, owner-defined safety rules are enforced by hooks, and the morning handoff is reviewable. No
host quietly clocks out with open work; each keeps the active objective and remaining work
available on disk through compaction or resume. Product-evolution and owner-walkthrough shifts also record the exact
next action and verification still due.

[Install](#install) · [Run a first shift](#run-a-first-shift) ·
[Origin story](#the-screen-that-made-me-build-nightshift) ·
[How it works](docs/how-it-works.md) · [Receipts](#receipts) ·
[Contribute](docs/contribution-map.md) · [Overview and FAQ](https://nightshift.orwamahmoud.com/)

## Install

### Codex and ChatGPT

[Install Nightshift from the official OpenAI Plugin Directory](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe).

For local Codex development, the same package can be installed from its marketplace:

```text
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Use Nightshift with the project you want it to change open in Codex — a Git repository or a
persistent local folder — or with Codex connected to its GitHub repository. If invoked from a
normal ChatGPT conversation backed by `/workspace/scratch/`, setup stops before writing anything
and points the user to Codex—the scratch files would not survive.

The punch-list gate, guards, skills, and crash revival are live-verified on Codex. A killed session
is resumed into its recorded conversation when `.shift-session` holds a resumable identity; a
missing identity uses the punch list to hand off to a fresh run, while a known non-resumable
identity stands down rather than opening an unrelated conversation. One boundary remains: a Codex
session that is alive but wedged on an API error is left alone until that signature has been
observed in the wild.

### Claude Code

Two commands inside Claude Code — no npm, no Homebrew, no separate CLI, no API keys, no server:

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift
```

### Platforms

macOS and Linux use the bundled shell runtime. Native Windows uses bundled PowerShell hooks,
process checks, recovery, and Task Scheduler generation; Git Bash and WSL are not dependencies.
WSL remains a Linux runtime and must keep the host, plugin, repository, and watchman inside the
same distribution. See [Native Windows](docs/windows.md) for the exact parity and conservative
limits, and [Remote environments](docs/remote-environments.md) for co-location requirements.

## Run a first shift

You do not need to learn the whole system first. Start with one small, concrete task in a project you
trust. Keep the first run attended so you can see how your permissions, gates, stop order, and
host-specific recovery behave.

Before leaving any run unattended, use the concise
[first-night safety checklist](docs/first-night-checklist.md).

| Action | Codex or repository-connected ChatGPT | Claude Code |
| --- | --- | --- |
| Set up | Ask: **“Set up Nightshift.”** | `/nightshift:setup` |
| Start | Ask: **“Start the shift.”** | `/nightshift:start` |
| Check status | Ask: **“Show shift status.”** | `/nightshift:status` |
| Diagnose | Ask Nightshift to diagnose the site | `/nightshift:doctor` |
| Stop the shift | Ask Nightshift to stop | `/nightshift:stop` |
| Reset runtime | Ask Nightshift to reset | `/nightshift:reset` |
| Remove project state | Ask Nightshift to purge this project's Nightshift data | `/nightshift:purge` |

1. Set up Nightshift and accept only the proposed gates you want.
2. In `.nightshift/punch-list.md`, add one small, concrete task under `## Items`:

   ```text
   - [ ] **1. <clear task title>.**
     - <exactly what must change>
     - Verify: <commands that prove it is done>
     - Commit: `<type: concise message>` (repository) or an artifact receipt (notes folder)
   ```

3. Start the shift.
4. Check status later. If the site looks wrong, diagnose it first; Doctor reports and never
   repairs.
5. Review the local commit or `$NS/receipts/` (Doctor names the most recently written file). Doctor warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts. Archive copies
   those files with `ns archive-receipts` (native Windows: `ns.ps1 archive-receipts`)
   into the dated folder and leaves the live copies in place. Missing or empty receipts create no dated receipts folder. Push only if this is a git repository.

If the host task and the workspace holding `.nightshift/` are different folders, use the explicit
link described under [Workspaces and repositories](docs/how-it-works.md#workspaces-and-repositories);
Nightshift never guesses which nearby folder owns a shift.

An unattended run cannot answer permission prompts. Claude Code can use a project-local
`bypassPermissions` setting offered by setup. A Codex run whose contract commits needs
`codex -a never -s danger-full-access`; `workspace-write` protects `.git` and therefore cannot
create the per-item commits. Nightshift's configured guards remain active in either mode.

Only four ideas matter on the first run:

- **Punch list:** the work the agent must finish.
- **Gates:** checks that must pass before an item is ticked.
- **Parking lot:** questions the agent records instead of waking you.
- **Shift log:** the record of progress and problems.

Product research, opportunity maps, drafting tables, work orders, hunts, the watchman, receipts,
and archives are useful later, but none is required to try one shift. The
[command reference](docs/commands.md) covers them when you need them.

## The screen that made me build Nightshift

![An agent checkpoint: the smaller fixes shipped, the bigger items deferred in the agent's own
words — and a question that has been waiting since the night
before](https://github.com/user-attachments/assets/a4816652-a2c1-4212-aff9-8a3dafd848a6)

I asked for eight things and stepped away. That screen is what I came back to:

- the four **easiest** items — done, shipped, wrapped in a proud little table;
- the four **hard** ones — “these deserve a focused session, I don't want to rush them.”

Buddy. *This* is the focused session. You're alone. It's just you and the list. What else is on
your calendar tonight?

That was the mild failure. The 02:40 question, the review loop that never converges, and the dead
session are the other nights behind the design. The
[full origin story](docs/why-nightshift.md) follows each one through to the mechanism Nightshift
uses against it.

Repeating “keep going” inside the same conversation does not make the instruction durable.
Nightshift moves the contract outside the conversation so the list and decisions survive the run.

## What happens during a shift

- **The list stays authoritative.** Open checkboxes remain open across compaction, restart, or
  recovery.
- **Start asks nothing.** One native preflight prints a verdict per line — `ok`, `warn`, or
  `refuse` — in the same words on every host, then arms or stops. A scheduled or headless start
  behaves exactly like an interactive one.
- **No Python, and no parser to install.** The plugin ships shell and PowerShell only. Hooks read
  `rules.json` with a bundled reader that needs neither `jq` nor `python3`, and an unreadable rules
  file fails closed instead of arming on a guess.
- **Configured rules are mechanical.** Optional command, path, identity, and secret guards are off
  by default; hooks enforce the ones the owner chooses.
- **One shift binds one session ID.** Start refuses to place a second agent beside a live shift; a
  separate helper conversation remains outside the gate and shift command guards.
- **Questions do not consume the night.** The shipped question-tool entries park them with a
  default and keep them reviewable; the owner can explicitly allow either host's question tool.
- **Finite work finishes; open-ended work has a clock.** Stall limits and deadlines bound retries
  when cost matters.
- **Dead sessions can recover.** Each watchman prefers the recorded session for its host and uses
  only its documented continuation or fresh-session fallbacks. Claude Code also exposes pause,
  clean-exit, and API-error signals; Codex recovery uses process and rollout evidence, with live
  API-wedge detection still tracked in [#41](https://github.com/orwa-mahmoud/nightshift/issues/41).
- **One recovered process owns the shift.** Before a watchman starts a replacement, it atomically
  advances a process lease. Observable tool calls from the older process are then rejected with an
  instruction to reopen the conversation; the recovered process resumes the durable session when
  possible and always inherits the on-disk punch list. This is not a project lock: other tabs and
  conversations work normally, while Start still refuses to arm a second shift beside the active
  one.
- **Reopen a revived Claude thread to refresh its view.** The headless worker already continues
  against the punch list; the owner does not need to watch it. An already-open IDE view cannot
  display turns appended by that worker, so reopen the thread when you want to inspect or interact
  with it instead of typing **Continue** in the stale view. The process lease prevents that older
  view from using tools. When a session ID was recorded, the watchman leaves resume links in the
  parking lot after the headless revival finishes successfully; otherwise recovery is recorded in
  the shift log. Live refresh is tracked upstream in
  [anthropics/claude-code#82655](https://github.com/anthropics/claude-code/issues/82655).
- **Reopen a revived Codex thread for the same reason.** `codex exec resume` continues the durable
  session without owner monitoring, while an already-open Codex Desktop view remains stale. Reopen
  it before interacting; the stale view cannot use observable tools after the watchman takes the
  lease, but it still cannot display the appended turns. The upstream gaps are tracked in
  [openai/codex#28259](https://github.com/openai/codex/issues/28259) and
  [openai/codex#21743](https://github.com/openai/codex/issues/21743). Fixes for these three
  display-synchronization issues would remove the manual reopen and make the handoff more
  consistent; they are not prerequisites for headless recovery or lease enforcement.
- **The handoff is inspectable.** Local commits, timestamps, decisions, snags, and recovery events
  remain in plain files.
- **The owner can always stop it.** Use the host command or
  `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" stop-shift` (native Windows: `ns.ps1 stop-shift`)
  to pause immediately even when the model is stuck. That writes `STOP` and stands the
  watchman down; hardhat stays until clock-out writes `ENDED`. Reset is the manual escape.
  `touch .nightshift/STOP` in the
  folder that contains `.nightshift/` (not beside `.nightshift-link`) is the panic marker and
  waits for the next Stop event; unfinished boxes remain open.

Read [How Nightshift works](docs/how-it-works.md) for recovery evidence, host differences,
workspace layouts, mechanical guarantees, and limits.

## One shift, start to clock-out

https://github.com/user-attachments/assets/06868e7a-0991-4156-bfa1-de5521da36d9

A recorded session, unedited apart from pacing. Three items on the punch list, `/nightshift:start`,
one commit each — and midway the agent announces it is finished and tries to end the session with
two boxes still open. The gate refuses and hands back the contract; it goes back to the list and
clocks out only once every box is ticked.

## When to call in the night shift

- **You already have a checklist.** Put each outcome and its verification in the punch list.
- **Your allowance is about to reset and you have no backlog ready.** Ask Hunt for the product
  evolution shift: it studies the product, its history, user needs, and relevant standards; ranks
  opportunities by evidence, value, effort, reversibility, and risk; then builds the strongest
  complete improvements on an isolated branch or in the persistent folder. During a long build, the active opportunity records
  completed work, rejected paths, the exact next action, and verification still due.
- **The API is failing and you are about to leave.** The watchman keeps checking and resumes the
  recorded conversation when the host can prove it died and the identity is resumable. The
  on-disk contract remains the handoff if a fresh fallback is required.
- **You want to plan with one model and execute with another.** Write the objective and acceptance
  into the items; the punch list is the handoff.
- **Your prototype demos well and is held together with tape.** Turn the shortcuts, mocks, and
  “good enough for the demo” paths into verified items, then let the night work toward the product
  version.
- **The wall of warnings has no owner.** `/nightshift:quality` surveys lint, types, tests,
  dependencies, documentation, accessibility, contracts, and security; fix now, draft selected
  findings for later, or ignore them.
- **The work must stop at an explicit boundary.** Run a bounded coverage, defect, dependency, or
  vulnerability shift, or use an open-ended walkthrough that ends at quitting time.

If you can write it as a checklist, you can hand it to the night.

## Receipts

**Start with the receipts, not the promise.** The evidence library leads with a 45-hour AdaptTable
contract that survived a Claude Code → Cursor handoff and became a human-reviewed 67-commit PR
covering six roadmap phases and 57 closed issues. It also includes a smaller four-hour first night,
Nightshift's self-build, a Codex hardening shift and a template for reporting bad nights without
hiding what happened.

Browse the timelines, checks and permanent links in
[`examples/`](examples/README.md).

The live `.nightshift/` state stays out of this repo — the same default nightshift sets for your
projects: your run history is yours, ignored by your repo, and versioned in its own local
receipts repo if you opt in at setup.

When those files grow, `/nightshift:archive` moves completed items, handled snags, and the rotated
journal into a dated archive without touching the active contract.

Every shift also renders one compact [Morning receipt](docs/morning-receipt.md): what ran, what
changed, what's parked, and what's next, in a view suited to owner, reviewer, or release reading.

## The ready shifts

Named GitHub issues can be copied onto the drafting table with `/nightshift:import-issues` — explicit
URLs or `owner/repo` plus numbers only. Nightshift never searches GitHub and never writes back.

You do not have to invent the night's work. `/nightshift:hunt` reads the catalog and can either let
you choose the work (**Guided**) or take your sentence as the objective and compose the entries that
serve it (**Automatic**). In Automatic the objective is binding: quality, coverage, or dependency
work never displaces a feature or design objective because its fingerprints were easy to find. Then
choose when execution begins:

| | **Review first** | **Run directly** |
|---|---|---|
| **Guided** | Pick one or more shifts, inspect the assembled order, then approve or park it. | Pick the shifts and let Nightshift discover, implement, and verify their work without another pause. |
| **Automatic** | Say what you want and set the hours; Nightshift composes the work that serves it, but waits for approval before the clock starts. | Say what you want, set the hours, and leave; Nightshift starts the clock, works the entries that serve your objective, and keeps shipping until quitting time. |

Copyable owner requests for each cell are in [Shift modes](docs/shift-modes.md).

Every combination becomes one ordered work order, one deadline where required, and one set of
receipts. Review-first discovery is read-only and arms nothing until approval. Run directly is
explicit authority to cut and arm the shift immediately; significant decisions and rollback
instructions remain in the parking lot for morning review.

For your own high-level hours-cycle, choose **Guided → Owner walkthrough**, enter the objective in
the scope question, set the hours, then review it first or run it directly. The objective is
required and preserved verbatim; Nightshift derives coherent units, verifies each one, and keeps
the active unit's exact next action on disk until quitting time. This entry is never selected
automatically.

Each entry declares how it ends. **Open-ended** entries have no natural end but the clock, so Hunt
requires hours and a walkthrough never runs without a cost cap. **Finite** entries work a known
list and end when it is clear, so hours are a cap rather than a requirement.

The entries live one per file in
[`shifts/`](plugins/nightshift/skills/nightshift/references/compose/shifts/) — read that directory for the current set
and the exact contract of each. No page enumerates them.

**Running a night that isn't in there? Add it.** Catalog entries are the easiest contributions to
review and merge: one Markdown contract and its focused test, with no shared hook change. Each
entry lands in its own file, so nothing you write collides with anyone else's.
The [contribution map](docs/contribution-map.md) and
[`catalog-recipe.md`](plugins/nightshift/skills/nightshift/references/compose/catalog-recipe.md) show the
two files and checks.

## Built into every host, not pasted into a prompt

Nightshift ships native skills and hook wiring for Claude Code, Codex, and Cursor from one package.
It wraps nothing and proxies nothing. The skills carry the working method, disk files keep the objective,
evidence, and decisions available across compaction or resume, and hooks enforce the boundaries
each host exposes.

Both hosts provide the Stop event used by the clock-out gate. Their recovery evidence differs:
Claude Code exposes Escape, clean session-end, process, transcript, roster, and API-error signals;
Codex exposes process and rollout activity, requires a resumable identity for same-conversation
revival, and does not yet classify a live API-error wedge.

Nightshift does not repair either host's conversation history. It keeps the working contract
independent of that history. The precise boundaries are in
[How Nightshift works](docs/how-it-works.md#different-strengths-on-each-host).

## Documentation

- [**Evidence and receipts**](docs/evidence-capabilities.md) — the ledger, receipt templates,
  profiles, tooling policy, artifact mode, and cross-host handoff.
- [**Maintainer verification matrix**](docs/maintainer-verification-matrix.md) — where each shipped
  surface lives and which tests hold it.
- [**Why Nightshift exists**](docs/why-nightshift.md) — the failure modes behind the contract.
- [**How Nightshift works**](docs/how-it-works.md) — files, gates, recovery, host differences,
  workspace layouts, guarantees, and limits.
- [**Native Windows**](docs/windows.md) — PowerShell lifecycle parity, Task Scheduler, and limits.
- [**Remote environments**](docs/remote-environments.md) — local, Remote SSH, devcontainer, and
  split-runtime evidence.
- [**First-night safety checklist**](docs/first-night-checklist.md) — what to verify before leaving.
- [**Shift modes**](docs/shift-modes.md) — copyable Guided/Automatic × Review first/Run directly walkthroughs.
- [**Command reference**](docs/commands.md) — every command, natural-language Codex equivalents,
  and offline paths that need no session.
- [**Troubleshooting**](docs/troubleshooting.md) — read-only diagnosis before changing files.
- [**Owner knobs**](docs/knobs.md) — every rule available for a shift and what it denies.
- [**Vocabulary**](docs/vocabulary.md) — each Nightshift term and the file behind it.
- [**Contribution map**](docs/contribution-map.md) — choose an area, issue, likely files, and checks.

## Before trusting an overnight run

- Run the first shift attended in a trusted git repository or a persistent folder — never a
  disposable ChatGPT scratch workspace.
- Review first is read-only. Hand-written or already queued work starts at `/nightshift:start`;
  **run directly** from Hunt or Quality is an immediate start order.
- Configure permissions before leaving. A headless run cannot approve a tool prompt.
- No lint or tests is a first-class setup path. The item definition of done must carry the proof
  when project tooling cannot.
- Ticks are self-reported. The gate re-injects the working contract at every blocked stop, but item
  checks and human review still determine whether the work is good.
- Hardhat is hardening, not a sandbox: it matches command text. Default `rules.json` denies five
  elevation categories — `sudo`, containers (Docker socket and create-state verbs), global
  packages, daemons, and external services — unless the owner explicitly allows them. Read-only
  forms such as `docker ps` and `brew list` are not elevation. The patterns stop accidental drift
  by a cooperative agent; they are not unbypassable isolation.
- Completion beats cost by default: a stuck finite shift is held and flagged rather than silently
  ended. Bound it with a deadline, `NIGHTSHIFT_STALL_MAX`, or both when cost matters more.
- The stall guard treats ticks, commits, and artifact receipts as progress, so failed-attempt commits can look alive;
  the item gate and deadline remain the backstop.
- Stop the shift at any time with the host command, `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" stop-shift`
  on POSIX, or `ns.ps1 stop-shift` in native Windows PowerShell.
  `touch .nightshift/STOP` on POSIX, or
  `New-Item -ItemType File -Force .nightshift\STOP` in native Windows PowerShell, still writes the
  panic marker in the folder that contains `.nightshift/`, not beside `.nightshift-link`.

The complete behavior and trade-offs are in [How Nightshift works](docs/how-it-works.md).

## Codex wedge detection

Gate, guards, skills, scheduling and the watchman all run on OpenAI Codex from the same package.
The one open edge is wedge detection: a Codex session alive at an API error is stood by, not
revived, until that transcript signature has been observed during an outage — see
[#41](https://github.com/orwa-mahmoud/nightshift/issues/41).

## Contributing

Human and AI-assisted contributions are welcome. Use the
[contribution map](docs/contribution-map.md) to choose catalog, documentation, testing, runtime,
recovery, hook, platform, or public-run work. Repository checks and the release process are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[MIT](LICENSE) © [Orwa Mahmoud](https://orwamahmoud.com)
