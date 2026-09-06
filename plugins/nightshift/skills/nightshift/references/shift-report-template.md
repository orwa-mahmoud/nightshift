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

## Usage, per item

Per-item accounting is Nightshift's own job, not something a host has to support. The lifecycle is
the same everywhere:

1. **Baseline** — record the usage the session reports when the item starts.
2. **Track** — while the item is active. Where the host exposes cumulative counters, the item's
   consumption is the delta against its baseline. Where the host emits individual usage events
   instead, sum the events that belong to the active item.
3. **Finalize** — calculate the item's consumption when it finishes, and write it into the section
   before the tick.
4. **Reset** — drop that item's counters. The next item starts from its own baseline.

The only real dependency is access to reliable usage data. A host that reports nothing usable
makes the block `unavailable` — never zero, never an estimate presented as a measurement.

```text
Usage: input <n> · output <n> · cache read <n> · cache write <n> · reasoning <n>
  Cache read is <included in|separate from> the input figure above.
  Source: <host> <model>, <cumulative counters|per-event sums>, <session|scope>
```

Report every dimension the host actually exposes, separately and by name — input, output, cache
reads (the cached input a request was served from), cache writes (what a request added to the
cache), and reasoning output where a model reports it apart from its visible output. Mark any one
`unavailable` on its own when the host reports the others but not that one, and leave out a
dimension the host has no concept of rather than writing a zero for it.

Say whether cache reads are already inside the input figure, so nothing is counted twice, and the
same for reasoning inside output. Never turn a token count into a price.

**A progress update is not a finish.** It resets the cadence window — the clock or the token
threshold that decides when the next update is due — and nothing else. The item's own totals keep
accumulating from the baseline it started with, so two updates inside one item never split its
usage into two items' worth.

**Finishing an item resets that item, not the shift.** Write the item's final figures, tick, then
drop that item's counters so the next one starts from its own baseline. The running shift totals
carry on: they are the sum of the items measured so far, and clearing them at a tick would leave
the outcome with nothing to add up.

## The outcome

Added at clock-out, from the sections already written — not by re-reading the night.

```text
## Outcome

<What the shift delivered, in a few lines. What is still open, and what the owner should look at
first.>

Shift usage: input <n> · output <n> · cache read <n> · cache write <n> · reasoning <n>
  Items measured: <n of n> · Shared overhead: <n, or unavailable>
  Coverage: <complete|partial — and what is missing>
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
