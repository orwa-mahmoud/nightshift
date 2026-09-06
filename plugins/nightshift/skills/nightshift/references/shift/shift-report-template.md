# Shift report template

The shift writes `.nightshift/shift-report.md` as it works: a header, then one section per
punch-list item, then a short outcome at the end. Copy the blocks below and fill every field.
This is the narrative of what was delivered and why — the shift log stays the execution journal,
the snag log the findings, the parking lot the decisions. Link to those; never copy them here, and
never put any of it in a public commit message.

## Header

Written once, when the first item starts.

```text
# Shift report

- Shift: <shiftId, or the date when no policy carries one>
- Objective: <what this shift was cut to do, in one line>
- Host: <claude|codex|cursor> · <work mode>
- Status: <in progress | done | stopped | quitting time>
```

## An item section

One per punch-list item, headed by that item's own id. Start it when substantive work on the item
starts — not when you read the item, and not after it is finished.

```text
## <item id> — <the item's own title>

State: <in progress | done | corrected>

<While it is running: one short paragraph on where this has got to and what is left. Update this
paragraph in place; never append another status snapshot under it, and never write it as though
the item were finished.>

Result: <what a user of this project gets from the item, in their terms>
Changes: <the changes that mattered, and why they were made that way>
Verification: <the commands that actually ran and what they returned, plus what they could not
cover. A cadence that skipped the gate says so — never describe a check that did not run.>
Outputs: <paths, commit subjects, or artifact locations that locate the real deliverables>
Related: <snag-log and parking-lot entries this item touched, by their own wording>
Usage: <the block below, or `unavailable` with the reason>
```

## Usage and duration, per item — written by the runtime

These two lines are not yours to write. The runtime reads them from the records the host already
keeps — Claude Code's session transcript, Codex's running token count, Cursor's stop payload — and
appends them to the item's section at the tick. They are described here so you know what the
section will contain, not so you can produce one.

```text
Usage: input <n> · cache_write <n> · cache_read <n> · output <n> · reasoning <n>
  Source: <host> <model>, cumulative counters, segments <n>
  <one sentence saying what is already counted inside what, for that host>
Duration: <wall clock from the previous tick to this one>
```

Every dimension is named. One the host does not report reads `unavailable` rather than zero,
because zero is a measurement and silence is not. The overlap sentence is the host's own
arrangement — Anthropic keeps cache separate from input, Codex counts cache inside input and
reasoning inside output, Cursor's input overlaps its cache figures — so nothing downstream adds
the same tokens twice. Totals are never summed across hosts, and a token count is never turned
into a price.

Where a host reports nothing usable, the line says so and the shift carries on. An unmeasured item
is not a failed item.

## The outcome

Added at clock-out, from the sections already written — not by re-reading the night.

```text
## Outcome

<What the shift delivered, in a few lines. What is still open, and what the owner should look at
first.>

Shift usage: input <n> · cache_write <n> · cache_read <n> · output <n> · reasoning <n>
  Items measured: <n of n> · Shared overhead: <n, or unavailable>
  Duration: <wall clock for the shift> · Paused: <where the runtime knows a gap was not work>
```

The shift total is the measured item totals plus the shared overhead that belongs to no single
item — planning, reporting, and anything between items. Say plainly whether that coverage is
complete or partial rather than presenting a partial sum as a whole one. A subagent's usage joins
an item only when the parent and child numbers and the item it belongs to are all known; where a
parent total already includes its children, it is not added again.

## What never goes in

A dollar figure derived from token counts. An estimate written as though it were measured. A
number carried over from another session, model, or shift. A negative delta. Anything from
`ai_docs/`, a private path, or the owner's own words about their plans.
