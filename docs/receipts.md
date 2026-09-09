# Receipts and token usage

Receipts answer three questions: what did the agent deliver, how was it checked, and what did each
item consume? They live under `.nightshift/receipts/`: a runtime-written index, one model-written
file per punch-list item, and the morning receipt. You can read an unfinished item's progress
without waiting for the whole shift to end.

## Read the work item by item

Each item has its own file: what was delivered, why, what was tried and rejected, verification,
outputs, and related snags or decisions. While it runs, a short progress paragraph records what is
done and what remains. The closing paragraph replaces that when the item finishes.

At clock-out, the [morning receipt](morning-receipt.md#the-morning-receipt) is the compact ending
and evidence summary. The [example receipts](../examples/receipts.md#receipts) show an index and
one item file.

## Token usage is measured by the runtime

The hooks read the host's records and append usage and duration to the item's receipt at its tick.
The agent does not estimate its own consumption. Accounting boundaries follow ticks: work between
two ticks belongs to the item closed by the second, including its verification. This is useful
attribution, not a profiler of individual edits; items ticked together can share a reading.
Duration is wall-clock time, with known idle gaps identified rather than silently removed.

| Host | Measurement source | How to read the figures |
| --- | --- | --- |
| Claude Code | Session transcript | Repeated response records are deduplicated. Cache reads and cache writes are separate from input. |
| Codex | Rollout token counter | Cached input is already included in input; reasoning is already included in output. |
| Cursor | IDE stop payload | Input overlaps cache figures. Reasoning and subagent usage are not reported; recovered CLI segments have no per-turn usage source. |

Input, output, cache reads, cache writes, and reasoning retain their names and host-specific
meaning. Missing measurements are marked `unavailable`. Recovery, model changes, and counter
resets open new segments instead of subtracting incompatible counters. Totals are not added
across hosts, and tokens are never converted into an estimated price. Usage already spent before
the shift began is excluded from its accounting.

## Choose when progress updates appear

Receipts default to progress updates after 20 minutes of work on an item. You can choose:

- **Time:** update after the configured minutes.
- **Tokens:** update after the configured token threshold; fall back to time when no counter is available.
- **Either:** update when either threshold is reached.
- **Completion only:** write the finished receipt without intermediate updates.

The runtime checks the cadence when a tool returns, so it does not interrupt a running command.
These thresholds control how often the progress paragraph is refreshed; they do not end a shift
or enforce a token budget. Use the shift's deadline and stall settings to bound continued work.

The settings are `receipts.progressMode`, `receipts.progressMinutes`, and `receipts.progressTokens`.
`receipts.usage` defaults to `when-available`; `off` disables usage measurement and the runtime's
progress-due notices. `receipts.enabled=false` disables receipt files while retaining the work
contract and other records. See [Owner knobs](knobs.md#shift-handoff-and-archive) for the exact
settings.

## Keep the receipts useful after the shift

Review the actual outputs and checks alongside the receipts. When you [archive the shift](archive.md#archive-and-continue),
the receipts folder is filed with its records, links are adjusted for the new location, and an
untouched original is preserved. Open work retains the evidence it needs for continuation.

[Review the underlying evidence](evidence-capabilities.md#reviewing-a-shift) ·
[Choose the next shift](shift-modes.md#shift-modes) · [Documentation index](README.md#documentation)
