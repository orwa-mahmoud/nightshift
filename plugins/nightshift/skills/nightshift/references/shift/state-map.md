# State files

What each file under `.nightshift/` holds. One copy; every skill that stages, promotes or files
work points here.

- `punch-list.md` → owner-approved work active in this shift.
- `drafting-table.md` → known work staged for a later shift.
- `parking-lot.md` → unresolved owner decisions plus the default chosen so work continues.
- `work-orders.md` → timed catalog work composed only through Hunt.

Ordinary plans belong in the drafting table, never in Hunt or the parking lot. Each file keeps its
own lifecycle; never reclassify one as another.

## Every file, and who writes it

**Written by** names who may change the file: the owner, the agent (the model working the shift or
running a skill), or the runtime (hooks, helpers and watchmen). **Rebuilt** says whether the
runtime can regenerate it from other records; a file that is not rebuilt is a record to keep.
While a shift is armed, hardhat refuses writes to `rules.json`, refuses deleting the punch list,
and refuses deleting or forging the control files: `STOP`, `.shift-armed`, `.ended`,
`.shift-session`, `.shift-worker`, `.shift-lease`, `.mutex-scope`, `work-target`, `work-mode`,
`shift-policy.json`, `shift-defaults.json` and `deadline`.

### Work and decisions

| File | Written by | Rebuilt | Changes | Leaves live storage | Governed by |
|---|---|---|---|---|---|
| `punch-list.md` | Owner, and the agent through Start, Hunt or Quality. The agent ticks boxes. The runtime adds each item's `<!-- id: … -->` comment when the shift policy is written, before arming. | No | Composed before arming; while armed only boxes tick | Once the shift has ended, `archive-receipts` files the contract and the ticked items as the shift folder's `punch-list.md`; open items stay | The contract above `## Items`; its digests in `shift-policy.json` |
| `drafting-table.md` | Owner, the agent, Import issues | No | When work is staged, or cut into the punch list | Start moves an item out when it cuts it; never archived | — |
| `work-orders.md` | Hunt | No | Hunt composes; Start cuts | Archive files an order ticked in place and drops an empty heading | — |
| `parking-lot.md` | The agent parks decisions. The runtime adds permission gaps (`park-needs`) and watchman revival notices. The owner answers. | No | During the shift; answered in the morning | Archive files answered entries and leaves a `Filed:` pointer | — |
| `snag-log.md` | The agent. The runtime adds a broken archive-pointer entry. | No | As findings are made and dispositioned | Archive files handled entries and leaves a `Filed:` pointer | `finding · evidence · disposition · date` |
| `shift-log.md` | The runtime (gates, watchman, Stop and Reset) and the agent | No | Every cycle and control event | Start rotates it into the archive past about 500 KB; Archive moves it whole | — |
| `product-research.md` | The agent | No | Product-evolution cycles | Between shifts Archive appends its entries to the archive copy and restores the template | — |
| `opportunity-map.md` | The agent | No | Product-evolution cycles | Archive files `shipped` and `rejected` entries | Statuses in the template |
| `capabilities.json` | The agent, after a tooling commit lands | No; the agent reads the manifests again | After a tooling commit | Never | — |

### Configuration

| File | Written by | Rebuilt | Changes | Leaves live storage | Governed by |
|---|---|---|---|---|---|
| `rules.json` | Setup, from the template; then the owner | Setup copies the template only when the file is missing; Start names a new template key and never adds it | Between shifts | Never | `nightshift-rules.schema.json` |
| `shift-policy.json` | The runtime: composition (`shift-policy.sh`), or the snapshot Start takes | No | Before arming; frozen while armed | The clock-out gate files it as `shift-policy-<shiftId>.json` in the shift's folder; Reset drops it | `schemas/v1/shift-policy.json` |
| `shift-defaults.json` | Older workspaces only | — | Never written now | `shift-policy migrate` moves its choices into the `shift` block of `rules.json` and keeps `shift-defaults.json.bak` | `schemas/v1/shift-defaults.json` |
| `state-version` | Setup; `migrate-state` | No | On a state migration | Never | Current version `1` |
| `work-target`, `work-mode` | Setup | Setup writes them again | When the owner re-points the workspace | Never | — |
| `deadline` | Start, from the composed hours | No | When a shift with hours is cut | Start drops it once it has passed; Reset drops it | UNIX epoch seconds |
| `.gitignore` | Setup, with the receipts repository | Setup adds any missing marker line | At Setup | Never | — |
| `.git/` | Setup, only when the owner asks for a receipts repository | No | Commits by the clock-out gate and Archive when `receiptsAutoCommit` is true, else by the owner | Never; never pushed | — |

### Records the runtime writes

| File | Written by | Rebuilt | Changes | Leaves live storage | Governed by |
|---|---|---|---|---|---|
| `receipts/<id>-<slug>.md` | The agent writes the prose. The runtime keeps its `<!-- item: … -->` comment and a `Renamed from` line current, writes the Tokens and Time tables at the tick, and adds a Sessions row as each span on the item closes. The file name comes from the item's id. | No | From the first substantive work until the tick | `archive-receipts` copies it into the shift folder, and retires it from live storage once the shift has ended and its item is ticked; an open item's stays | `references/receipts/` shapes; `receipts.*` settings |
| `receipts/README.md` | The runtime | Yes, from the punch list and receipts | Every tick, arming, clock-out, and archive | Archive rebuilds it on both sides of the move | — |
| `receipts/morning-<date>-<shiftId>.md` | The clock-out gate, unless the agent already wrote the page the owner's template asks for | Yes, while its records are live | Once, at clock-out | Archive copies it into the shift folder and retires it when it is named with `--retire` | `handoff.*` settings |
| `receipts/previous-report.md` | `migrate-state`, from the single page an older layout kept beside the punch list | No | Once | Archive copies it; it leaves live storage only when named | — |
| `usage/` (`segments.tsv`, `marks.tsv`, `pauses.tsv`, `active`, `window`, `previous-pulse`, `previous-ticked`, `.ticked-now`) | The runtime | No | Every pulse, tick, switch of item, and pause | The next Start renames it `usage-<shiftId>/`, and Archive files that | — |
| `evidence/findings.jsonl` | The agent, through the ledger helper, which validates each record | No | Append-only during the shift | The clock-out gate files it as `findings-<shiftId>.jsonl` and empties the live ledger | `schemas/v1/finding.json` |
| `archive/` | The clock-out gate, `archive-receipts`, the Archive skill | No | Each clock-out and each Archive | Only `retain-history --apply`, when the owner set `retention.archiveDays` | `archive.root`, `archive.layout` |
| `scheduled.log` | Scheduled runs | No | Each scheduled run | Only `retain-history --apply`, when the owner set `retention.runtimeLogDays` | — |
| `support/` | `export-support`, on request | Yes | On each export | Never automatically; the owner removes it | — |
| `provision-transaction.json`, `provision-baseline/`, `provision-surface` | `provision` | No | Around a provisioning step | Removed when the step commits or rolls back | — |

### Markers the runtime keeps

All of them are generated, and none is archived. Setup's `.gitignore` lists the transient ones.

| File | Written by | Means | Removed |
|---|---|---|---|
| `.shift-armed` | Start | The site is on shift: the clock-out gate and hardhat apply | The clock-out gate, when the shift ends; Start clears a stale one before arming; Reset |
| `.shift-session`, `.shift-lease` | Hardhat, on the binding probe; the watchman advances the lease | The bound conversation, and the generation that may work | Stop drops the session; the clock-out gate releases the lease; Start and Reset clear both |
| `.shift-worker` | The Cursor watchman | The CLI worker a revival resumes | Start; Reset |
| `.ended` | The clock-out gate | The shift ended, with `shiftId=`, `archiveRoot=`, `archiveLayout=` | Start; Reset |
| `STOP` | Stop, or the owner's terminal command; the gate writes `deadline` or `stalled` | A stop-work order and its reason | Start; Reset |
| `.pending-filing` | The clock-out gate, when `archive.automatic` is true | Filing is due for that shift | Archive, once filing is done |
| `.stall`, `.notified`, `.clock-out-reminder`, `.context-reset`, `.receipt-due`, `.report-due` | The clock-out gate, the pulse, and the session-start hook | Stall count, whistle sent, the reminder to repeat, a compaction to answer, a progress update due | By the step that consumes each; Start and Reset clear `.stall` and `.notified` |
| `.shift-pulse`, `.session-end`, `.watchman`, `.watchman-tick`, `.watch-reason`, `.mint-failed` | The pulse, the session-end hook and the watchman | Liveness, a clean close, the watchman's pid, its last wake and reason, a failed worker mint | The watchman removes its pid file when it exits; Start and Reset clear `.shift-pulse`, `.session-end`, `.watchman-tick` and `.mint-failed`; Reset drops `.watch-reason` |
| `.lock.d/`, `.lease-lock.d/`, `.mutex-scope`, and `*.tmp.*` beside a file | The runtime | Locks and atomic-write staging; `.mutex-scope` scopes native Windows mutexes | When the operation finishes; Start and Reset clear a stale lock |
