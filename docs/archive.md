# Archive and continue

Archive keeps completed shifts readable while leaving the next shift's work close at hand.
Ask Nightshift to archive the finished shift, or use `/nightshift:archive` in Claude Code.
It files the records; it does not complete tasks or reset the work contract.

## What happens to the records

The default destination is `.nightshift/archive/`, grouped by date. You can instead group by
shift and choose another archive directory within `.nightshift/`. Filing preserves evidence;
retiring a live record is a separate choice based on whether unfinished work still needs it.

| Record | What Archive does |
| --- | --- |
| Completed punch-list items | Moves them into the archive's shipped-work record. Open items, the contract, and gates stay live. |
| Shift log | Files the journal and starts a fresh log. |
| Snags and parked decisions | Files handled entries; unresolved findings and unanswered decisions stay live. |
| Work orders | Keeps pending work available for a later shift. |
| Product research and opportunity map | Preserves research and terminal outcomes with their evidence. Candidate, building, and parked opportunities stay live. |
| Reports, receipts, and usage records | Files the finished shift's records. Live receipts are copied; records still needed for continuation remain available. |

The archived report's links are adjusted so its evidence remains reachable. An untouched original
is preserved beside it. Archive also writes a history index with objectives, outcomes, verification,
evidence locations, and continuation context, so later shifts can revisit earlier work without
reconstructing every conversation. Missing information stays marked as missing.

## File automatically at clock-out

Set `archive.automatic=true` if you want filing included in the end-of-shift flow. It is off by
default. The gate ends the shift first, then asks the agent to run Archive before the session
finishes. Automatic filing does not authorize deleting old history.

Prefer archiving between shifts. During an active shift with open items, Archive asks before
moving records so the current review remains intact.

## Start the next shift with the right contract

Review the remaining open items, unresolved decisions, and any opportunity still being built.
The contract and gates above the punch-list items still bind the next shift: archiving does not
silently replace them. Use [Start](commands.md#command-reference) to continue queued work or
[Hunt and Quality](shift-modes.md#shift-modes) to compose the next shift. Prior evidence can inform that work;
an archived action is not permission to repeat it.

## Keep or prune history

History is kept indefinitely by default. Retention settings can make old generated records
eligible for removal, but Archive previews the exact paths and requires an explicit confirmation
before deleting them. Live work and owner-authored files are outside that pruning operation.
See [retention and archive settings](knobs.md#shift-handoff-and-archive) and the
[Archive contract](../plugins/nightshift/skills/archive/SKILL.md) for the precise boundaries.

[Read the receipts and token usage](receipts.md#receipts-and-token-usage) ·
[Review the morning receipt](morning-receipt.md#the-morning-receipt) · [Documentation index](README.md#documentation)
