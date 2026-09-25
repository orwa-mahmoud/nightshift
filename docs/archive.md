# Archive and continue

Archive keeps completed shifts readable while leaving the next shift's work close at hand.
Ask Nightshift to archive the finished shift, or use `/nightshift:archive` in Claude Code.
It files the records; it does not complete tasks or reset the work contract.

## What happens to the records

Each shift gets one folder under `.nightshift/archive/`, laid out exactly like the live site, so a
filed shift reads the way it did while it ran:

```text
archive/2026-09-25/
├── punch-list.md            the whole list as the shift ended
├── receipts/                every receipt, the morning page, and an index
├── inbox/
│   ├── parking-lot.md
│   └── snag-log.md
└── run/
    ├── shift-policy.json
    ├── shift-log.md
    └── usage/
```

The folder is named by `archive.layout`: by date (the default, `2026-09-25/`, then
`2026-09-25-shift-2/` for a later shift that day), by shift id (`shift-<id>/`), by name
(`archive-follow-ups/`), or by date and name (`2026-09-25-archive-follow-ups/`). The name is the one
on the punch list's title line — `# Punch List — Archive follow-ups` — and a shift with no name
files by date. Clock-out claims the folder, and filing the same shift again returns to it, on
whatever day you run Archive. You can also choose another archive directory within `.nightshift/`.

Every record is filed as it stands; the live files then keep only what is still open:

| Record | Filed | Stays live |
| --- | --- | --- |
| Punch list | The whole list: contract, gates, ticked and open items | The contract, the gates, and the open items |
| Receipts | Every receipt, the morning page, and an index of the folder | The receipts of open items |
| Snag log and parking lot | Each file whole | Open findings and unanswered decisions, plus a `Filed:` link to the copy |
| Shift log, usage readings, policy | Moved into `run/` | A fresh shift log |
| Work orders | Orders ticked in place | Pending orders |
| Product research and opportunity map | Research and terminal outcomes with their evidence | Candidate, building, and parked opportunities |

Links between filed records keep working as written. A link to a record that stayed live is
adjusted so it still reaches it, and an untouched original is preserved beside the adjusted page. Archive also writes a history index with objectives, outcomes,
verification, evidence locations, and continuation context, so later shifts can revisit earlier
work without reconstructing every conversation. Missing information stays marked as missing.

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
