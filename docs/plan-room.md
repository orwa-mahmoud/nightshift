# The plan room

The plan room is where you and the agent design a shift before anything is built. Open it with
`/nightshift:plan`. While it is open, the agent reads the code, its
tests and history, searches, browses and asks you questions, but it cannot change your project:
its edit tools write only the plan's own files, and `git commit`, `git push` and `git tag` are
blocked. The room is bound to the conversation that opened it, so every other conversation in the
project keeps working normally.

## One file per plan

Each plan is its own file in `.nightshift/staging/plans/`: a complete punch list with its own
contract, checks, notes and items, so plans never mix. When you enter the room, the agent lists your
plans with their open items and asks whether to continue one or start a new one. A new plan takes
the name you give it and starts from your punch list's contract and checks.

Prepare as many plans as you like. When the punch list is empty, `/nightshift:start` offers them by
name and runs the one you pick; the next one waits its turn. The drafting table stays for loose
items you want to keep for later.

## Design the work together

Bring a feature, a refactor, a bug, or a whole backlog. `/nightshift:import-issues` stages
specific GitHub issues onto the drafting table as quoted source.

The agent reads before it asks: it opens the files, tests and history the question touches and
names paths and lines. For each decision that matters it lays out two or three options with what
each costs and buys, and says which one it would pick and why. A flow, a state machine or a
component boundary can come back as a diagram. When the discussion moves on, the decision is
restated in one line so it is not reopened by accident.

Saying "just build it" does not leave the room. The agent tells you the room is still open and how
to leave it.

## The plan record

Every decision lands in `.nightshift/staging/plan-record.md` as the conversation moves: where the
discussion stands, what was decided and why, the options rejected with the reason, and the
questions still open.

```text
- **Session export** · open since 2026-11-14 09:12 (UTC+04:00)
  - Where we are: export format agreed; next, how a partial export reports itself
  - Decided: stream rows instead of buffering — exports reach 2 GB
  - Rejected: a background job queue — adds a service for one feature
  - Open: does an export include archived rows?
```

Compaction, a closed tab or a new day loses nothing. The next time you open the room, the agent
reads the record first and picks up where it left off. A rejected option stays rejected unless new
evidence appears, and then the agent names the evidence next to the original reason.

## Stress-test the plan

When you enter the room, the agent asks once what you want to plan and whether you want any of these
for it. Pick any, all, or none; with none, they never come up again unless you ask. Whatever you
pick is applied as the work takes shape: evidence and edge cases on each item as it is drafted,
research when an open question needs it, the ordering check once there are several items, and the
pre-mortem when the list is nearly complete. Every line an option proposes is yours to keep, edit
or drop.

| Option | What you get |
| --- | --- |
| **Evidence lines** | An `Evidence:` line on each item naming what you will open to judge it: screenshots at named widths, before-and-after figures, a schema diff. Suggested from the [evidence catalog](evidence.md#the-evidence-catalog). |
| **Edge-case pass** | WHEN/THEN lines for the cases each item can meet, drawn from six packs: concurrency, environment, failure partway through, untrusted input, security, and state a later run will read. Your own packs are used first. |
| **Pre-mortem** | The agent answers "this shipped and failed a week later: why?" with two to five failure stories, each naming what broke, for whom, and what would have caught it. Each story you keep becomes a WHEN/THEN line, a new item, or a recorded non-goal. |
| **Ordering and risk check** | The item whose failure would break the most others, such as a shared contract, a data shape or a migration. The agent proposes moving it first or adding a checkpoint item right after it that proves the contract. |
| **Research** | Cited research on the questions the plan actually has, from the sources you name. Every source the plan relies on is cited in its design notes. |

Your answer is recorded in the plan record, so the question is never repeated for the same plan.

## Size it from your own history

As the list nears completion, or when you ask, Nightshift reads the working time and token totals of your past
receipts and estimates the drafted items: a figure per item, a total, and a suggested deadline. The estimate comes from your own shifts, never from a generic table. Until
there is enough history, it says so.

Most items need no limit. For an item with a real chance of getting stuck, such as an open-ended
investigation or a failure nobody has reproduced yet, the agent offers a
[budget](item-budgets.md#item-budgets) and says why: a soft limit, where it is told to finish, and a
hard limit, where only wrap-up is allowed. You decide whether to take it.

## What gets written

Planning is continuous. The agent drafts an item as soon as the discussion settles it, writes it to
the plan's file once you agree with it, and edits it in place when the discussion changes it, saying
each time what it wrote. Nothing reaches the plan that you have not agreed to. The plan's notes sit
in a `## Plan` section above its items:

```text
# Punch List — Stream session exports

…your contract and checks…

## Plan

Why: exports over 500 MB time out and users lose the download.
Scope: the export endpoint and its CLI command.
Non-goals: archived rows; a background job queue.
Design notes: stream rows; a partial export ends with an error trailer.
Record: `staging/plan-record.md` — Session export
Estimate: about 1h 40m and 3.1M tokens for 2 items

- [ ] **1. Stream the export endpoint.**
  - Replace the buffered writer with a row stream.
  - Budget: soft 45m / 1.5M tokens, hard 1h 15m / 3M tokens
  - Verify:
    - WHEN an export has 3 million rows THEN memory stays under 200 MB
    - WHEN the database drops mid-export THEN the file ends with an error trailer
    - `pnpm test exports`
  - Evidence: peak memory before and after for the 3-million-row fixture
  - Commit: `feat: stream session exports`
```

Items come in dependency order, each with a `Verify:` made of behaviour someone could
observe and a test could fail on. Before you start the plan, `ns check-items` names any item with
a missing or empty `Verify:`, a missing `Commit:`, an `Evidence:` that names nothing, or a `Budget:`
that does not parse. It refuses nothing: whether to start is your call.

## Review the last shift

When a shift has run since you last planned, the room opens with what it left for you: the morning
receipt, the receipts index, each parked decision, each snag without a disposition, and every item
still open or stopped at its hard limit. The agent walks you through them one at a time. A parked
decision gets your answer, a snag gets its disposition, and work to redo is drafted for the next
shift. The punch list stays yours to edit.

## Leave the room

Only you close the room. Type `/nightshift:plan-exit` to leave, or `/nightshift:start` to leave and
start the shift in one step. From any
terminal, `ns plan-exit` works on every host.

How the room holds the line, binds to one conversation, and reads your exit on each host is in
[How Nightshift works](how-it-works.md#the-plan-room).

---

[Evidence](evidence.md#evidence) · [Item budgets](item-budgets.md#item-budgets) · [Documentation index](README.md#documentation)
