# Evidence

Evidence is what you open to judge an item without rerunning it: the screenshot of the layout at
375 px, the benchmark figures before and after, the schema diff of a changed endpoint. You choose
it per item when you plan, the agent produces it while it works, and the item's receipt links it.

## Ask for it

Pick **evidence lines** when you enter the [plan room](plan-room.md#stress-test-the-plan),
or when Hunt composes a shift for review. The agent suggests one `Evidence:` line per item, next to
its `Verify:`, and you keep, edit or drop each one.

```text
  - Verify:
    - WHEN the card grid renders at 375 px THEN no card overflows
    - `pnpm test grid`
  - Evidence: before/after screenshots at 375 and 1280 px, light and dark
```

An item can carry several lines:

```text
  - Evidence:
    - the benchmark command, the machine, and before/after figures with run counts
    - the tests added and the behaviour each covers
```

`Verify:` is what must pass. `Evidence:` is what you look at to decide whether the result is right.

## The evidence catalog

Each entry in the evidence catalog tells the agent what to capture for one sort of change, how to
capture it, and what a reviewer checks in it. Nightshift ships ten:

| Entry | What you get |
| --- | --- |
| UI | Before and after screenshots at named widths, light and dark; a short recording for a flow of more than one step. |
| API or contract | A sample request and response and the schema diff; for a breaking change, old and new shapes side by side. |
| CLI or tooling | The command and its output before and after, including the error a user sees. |
| Performance | The exact command, the machine and its load, before and after figures with units, and the run count behind each. |
| Data or migration | Record counts before and after, the migration's own output, and the rollback command. |
| Configuration or infrastructure | The resolved config diff, the plan or dry-run output, and how the change is undone. |
| Refactor | What moved where and how unchanged behaviour was shown: the unchanged tests, a before/after output diff, or both. |
| Tests | The tests added, the behaviour each covers, and the coverage change for the touched files. |
| Security | The scan command and its output, and each finding's disposition. |
| Docs | The rendered page or a screenshot of it, and the link check output. |

When an item fits two entries, it gets the evidence of both, trimmed to what a reviewer would
actually open. When it fits none, the agent offers once to draft a new entry for you.

## What comes back

Evidence files land in the item's own folder, `.nightshift/receipts/<NN>-<slug>-<id>/`, beside its
receipt, and the receipt links each one. Name a file in backticks on the `Evidence:` line and the
agent saves it under that name:

```text
  - Evidence: the checkout step at 375 px with the keyboard open `checkout-375.png`
```

With `receipts.evidence.review` on, the agent opens what it produced, compares it with the item and the catalog entry, fixes what it sees, and says in the receipt what it
looked at. Archive files each finished item's evidence folder with its receipt.

## Decide what a missing file does

You choose how much weight a named file carries. `receipts.evidence.check` sets it for the shift,
and `check:` on an item's `Evidence:` line sets it for that item:

| `check` | A named file is missing |
| --- | --- |
| `off` | The tick stands. This is the default. |
| `report` | The tick stands, and the receipt and morning receipt list the missing file. |
| `block` | The item counts as open until the file exists, so the shift cannot clock out on it. |

When the evidence cannot be produced at all, `receipts.evidence.unavailable` (or `unavailable:` on
the line) decides: `hold` closes the item as stopped, `park` records a decision for you and keeps
working, and `note` ticks the item with the reason in its receipt.

## Evidence for the whole shift

Three settings apply to every item, each off until you turn it on:

- `receipts.evidence.default` gives every item without its own line the same request, such as
  "before/after screenshots for UI items".
- `receipts.evidence.fileMap` draws each item's changed files as a tree in its receipt, and the whole
  shift's in `.nightshift/receipts/shift-map.md`.
- `receipts.evidence.architecture` keeps one diagram of the components the shift touched,
  updated by the item that changes the structure.

## Add your own entries

Your review practice belongs in the catalog. An entry is one Markdown file: where it applies, the
evidence lines, how to capture them, how to check them, and what never goes in. Keep it in this
project's `.nightshift/catalogs/evidence/`, or in your user folder to use it in every project. An
entry with the same key as a shipped one replaces it, and the plan room suggests your entries
first. Add `kind: <key>` to an item's `Evidence:` line and that entry's file check applies to the
item as well.

[Add a catalog entry](add-to-a-catalog.md#add-to-a-catalog) walks through writing one. Every
setting on this page, with its default, is in [Owner knobs](knobs.md#shift-handoff-and-archive).

---

[The plan room](plan-room.md#the-plan-room) · [Receipts](receipts.md#receipts-and-token-usage) · [Documentation index](README.md#documentation)
