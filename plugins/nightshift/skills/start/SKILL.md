---
name: start
description: Begin the shift — preflight, cut whatever is queued, arm the site, work the punch list. Asks nothing, so a scheduled or headless run works exactly like an interactive one.
---

Start a Nightshift run in the host-opened project.

Resolve the host-opened project folder to an absolute `$TASK_ROOT`: use `${CLAUDE_PROJECT_DIR}` on
Claude Code; on Codex honor Nightshift's `${CODEX_PROJECT_DIR}` recovery override when present,
otherwise capture `pwd -P` before any other shell call. If `$TASK_ROOT/.nightshift-link` exists,
validate the one absolute workspace path inside it and call that `$NIGHTSHIFT_WORKSPACE`; otherwise
set `NIGHTSHIFT_WORKSPACE="$TASK_ROOT"`.

Bind the Nightshift directory once: `NS="$NIGHTSHIFT_WORKSPACE/.nightshift"`. On native Windows,
`$NS = Join-Path $NIGHTSHIFT_WORKSPACE '.nightshift'`. After this bind, Nightshift files are
`$NS/<name>` for every read, write, and shell command. Owner-facing prose may use the short names
(`punch-list.md`, `parking-lot.md`, `STOP`). Never re-resolve, never search surrounding folders.
Helpers that take `--project` or `-Project` still receive `"$NIGHTSHIFT_WORKSPACE"`. The shell's
working directory persists between Bash calls, so never rely on a bare relative path.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT`: use
`${CLAUDE_PLUGIN_ROOT}` on Claude Code; on Codex use `$PLUGIN_ROOT` when available; on Cursor use
`${CURSOR_PLUGIN_ROOT}` when available; otherwise derive it from the absolute path attached to
this skill (`skills/start/SKILL.md`). Substitute that absolute path in every command below; never
search for the plugin.

Host detail — native Windows paths, permission modes, resume commands, work-mode rules, the
stale-lease reset, and linking another workspace — lives in
`$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/start-hosts.md`. Open it when a verdict
below names your host, and not before.

**State map:** `punch-list.md` → owner-approved work active in this shift;
`drafting-table.md` → known work staged for a later shift; `parking-lot.md` → unresolved owner
decisions plus the default chosen so work continues; `work-orders.md` → timed catalog work composed
only through Hunt. Ordinary known plans never become work orders.

**With work in the punch list, this command asks nothing.** It reads the list, arms the site and
works — which is what lets cron run it at 04:00 and lets the watchman revive it after a crash. It
promotes nothing on its own: what is in the punch list is the shift, exactly as the owner left it.

The one time it speaks is when the punch list is **empty**. Then there is no work to do silently,
so it looks at staged drafts and pending Hunt orders and asks which to promote.

## 1. Preflight — one helper, one verdict per line

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/start-preflight.sh" --project "$NIGHTSHIFT_WORKSPACE" --host claude
```

Native Windows:

```powershell
& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\start-preflight.ps1" `
 -Project "$NIGHTSHIFT_WORKSPACE" -HostName claude
```

Pass the host you are actually running on (`claude`, `codex`, or `cursor`). Every line it prints is
one verdict:

- **`ok <topic> <detail>`** — a resolved fact. Report it if the owner asked; otherwise continue.
- **`warn <topic> <detail>`** — say it once in plain English, then arm anyway. The choice stays the
  owner's.
- **`refuse <topic> <detail>`** — do not arm. The `repair` line that follows is the exact repair;
  print it verbatim and stop. Exit status 0 means the shift may arm; non-zero is a refusal; 2 is a
  usage error in the call you just made.

The helper owns all of it, so the skill re-derives none of it: workspace and `.nightshift-link`
resolution, `state-version` (Start never writes the marker; migration is a Setup or Doctor repair
with `migrate-state.sh`, or
`& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\migrate-state.ps1" -Project "$NIGHTSHIFT_WORKSPACE"`
on native Windows), `$NS/work-mode` and `$NS/work-target`, the artifact receipts directory, the
process lease, `$NS/.shift-session`, a live watchman, the cross-host fence, an unrecovered
provisioning transaction, `rules.json` and the watchman recovery keys, the shift policy,
punch-list and staged counts, the deadline projection, and the host's permission mode. It reads
`rules.json` through `ns_rules_check`, so a broken file refuses to arm with one named reason
instead of a guess. Do not repeat any of those checks in the skill, and never install
`jq` or `python3` for them — the helper works without either.

The work-mode verdicts decide where the work happens. A malformed work mode, or a missing one where
Setup would propose artifact, refuse to arm and send the owner to Setup;
do not `git init` a notes folder. In artifact mode a receipts path that
exists but is not a usable directory refuses too. When `$NS/work-target` is unrecorded the
resolver takes the workspace or its single immediate child repository.
Skip a symlink or reparse child; it is not a nested checkout.

Liveness is process evidence, never a guess: the primary tell is `kill -0` on a recorded numeric
pid, and a pid that cannot be classified is `process-evidence-unavailable` — the helper stops
rather than reading a missing tool as a dead session.

Once it has proved no shift is live, the helper clears the leftovers itself: `STOP`, `.stall`,
`.notified`, `.ended`, `.session-end`, `.shift-pulse`, `.mint-failed`, `.shift-session`,
`.shift-armed`, `.watchman-tick`, `.lock.d/`, a stale `.watchman` pidfile, and the lease with its
temporary files. It never writes `.shift-armed`, never writes `$NS/deadline`, and never asks a
question, so a scheduled run behaves exactly like an interactive one.

These refusals carry a repair the owner must read word for word:

- `refuse control` — a paused shift with an expired deadline does not get a silent new budget. Do
  not clear `STOP`, do not ask for hours, do not invent a time budget. The decision comes from
  `ns_control_start_refuse_reason` (native Windows: `Get-NSControlStartRefuseReason`); the owner
  writes a new UNIX epoch to `$NS/deadline` or runs Reset then Start.
- `refuse binding` — the host opened one project and this Start was given another, and the two
  resolve to different workspaces. A shift would arm in one and record its session and lease
  against the other, so nothing is armed. Print the two paths the verdict names. The repair is the
  owner's: reopen the host on the project they mean, or point one at the other with a
  `.nightshift-link` holding that absolute path. Never pick one of the two yourself.
- `refuse provision` — recover before any product work with
  `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/provision.sh" --project "$NIGHTSHIFT_WORKSPACE" recover`
  (native Windows: `provision.ps1 -Project "$NIGHTSHIFT_WORKSPACE" recover`). When recovery exits
  unproven, Start refuses to arm and names the repair:
  `.nightshift/provision-transaction.json and provision-baseline/, restore by hand or run provision.sh rollback after fixing the target, then Start again.`
- `refuse fence` — the cross-host handoff fence refused. It is the same on-disk read as
  `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/continuity-handoff.sh" fence-check --project "$NIGHTSHIFT_WORKSPACE"`,
  which you may run to see the fence object; model-authored flags never grant takeover and two
  active workers are never permitted.
- `refuse lease` / `refuse session` / `refuse watchman` — an agent is already working this punch
  list, or its state is unowned. Hand the owner the running thread and stop; never start a second
  shift beside it and never kill a live watchman as stale. The trusted lever is
  `"$NIGHTSHIFT_PLUGIN_ROOT/runtime/stop-shift.sh" --project "$NIGHTSHIFT_WORKSPACE"`, which writes
  `STOP` and stands the watchman down. The panic form that only writes the marker —
  `touch "$NS/STOP"` on POSIX, or `New-Item -ItemType File -Force "$NS\STOP"` in native Windows
  PowerShell — waits for the next Stop event. For malformed lease state, print the stale-lease
  reset command from `start-hosts.md` for the owner to run themselves; do not run
  `ns_lease_reset_stale` from the blocked session, and when the verdict says
  `terminal clock-out failed without releasing the shift` do not run the stale-lease reset at all —
  reopen the recorded conversation.

Tonight's snapshot reads the same on every host, with or without `jq` and `python3`, so a
verification level, a tooling policy or an elevation allowance the owner recorded still applies.
`refuse policy` means this host has no reader for it at all, and a shift does not arm on a policy
nobody can read. `warn permissions` means a prompt mid-shift could freeze the night: say the cost
once and proceed, because the choice stays the owner's.

**Artifact mode completes with receipts, not commits.** When the verdict is
`ok work-mode artifact`, complete each item with
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/write-receipt.sh" --project "$NIGHTSHIFT_WORKSPACE"` (native
Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\write-receipt.ps1" -Project "$NIGHTSHIFT_WORKSPACE"`)
instead of a work-target commit. Completion there is `$NS/receipts/`, not a git log.

**Inspect capabilities in the skill.** Read manifests, lockfiles, and `## Gates` in the work
target. `$NS/capabilities.json` is a cache the model may update after a successful tooling commit
only; no detector is required.

**Permission gaps are parked, never asked.** Run
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/preflight-needs.sh" --project "$NIGHTSHIFT_WORKSPACE"`
(native Windows: `preflight-needs.ps1 -Project "$NIGHTSHIFT_WORKSPACE"`) against every item now in
`## Items`. For each item with a gap, run
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/park-needs.sh" --project "$NIGHTSHIFT_WORKSPACE"`
(native Windows: `park-needs.ps1 -Project "$NIGHTSHIFT_WORKSPACE"`) to add its entry to
`$NS/parking-lot.md` naming the missing category, then append one `$NS/shift-log.md` line listing
every gapped item. Work everything else. If either helper exits because no JSON parser is
installed, park the gaps in the skill and continue; neither is on the armed path.

## 2. The punch list is the shift

If `$NS/punch-list.md` has at least one open `- [ ]` under `## Items`, that is the work — start it.
Do not promote, cut, or add anything: parked orders and drafts stay exactly where the owner left
them. An empty `## Items` section still keeps the Shift contract and Gates; they bind whatever Hunt
or Start cuts next.

**Resume the active product cycle before rediscovery.** When the open item is product evolution,
inspect `$NS/opportunity-map.md` for its single `Status: building` entry before doing new research
or selecting work. Its `Next` action and `Verify remaining` are the continuation point. More than
one building entry is inconsistent state: keep the earliest one active, mark the others
`candidate`, record the repair in `$NS/shift-log.md`, and continue.

**Only when the punch list is empty, offer what is staged.** The `ok staged` verdict already counts
`$NS/work-orders.md` and `$NS/drafting-table.md`. Read both, show what they hold in one short list,
and ask which to work now. On the owner's choice, **cut it — move, never copy**: the item goes
under `## Items` and is removed from the file it came from, so it never exists in two places. An
imported draft (`Status: proposed` and a canonical `Source:` GitHub URL) is cut the same way in the
skill — move the item under `## Items` and remove it from the drafting table. The import-issues
helper is optional. Do not require Python. A flagged import stays refused unless the owner
overrides after seeing the flags. From a work order, remove the whole `## Work order` section
(heading, hours, and item), not just the checkbox, then write `$NS/deadline` as a UNIX epoch from
the recorded hours (`now + hours*3600`; compute now with `date +%s` on POSIX, or `Get-NSUnixTime`
after importing the module on native Windows); an order marked finite with no hours writes no
deadline.

If the punch list is empty and nothing is staged, stop and say so: Setup if the project is new,
Hunt to compose a shift, or write an item by hand. Give host-native invocation when needed: slash
commands on Claude Code, or ask Nightshift for the named skill on Codex.

The working tree should be clean enough to commit per item; warn if it is not.

## 3. Deadline — read, never asked

The deadline value is decided when the work is composed (Hunt's cut, the owner's own edit, or
Start's own start-defaults), never asked here. **The deadline is cleared only if it has already passed** — the preflight does that, because a shift that reached the whistle
would otherwise clock tonight out at zero items. A deadline still in the future is tonight's plan and is kept.

Act on the deadline verdict:

- `ok deadline <epoch> (policy …)` — the shift policy is the authority. Write that epoch to
  `$NS/deadline`.
- `ok deadline <epoch> (file …)` — keep the file as it is and record that epoch as the policy's
  `deadlineEpoch`, logging the adoption in `$NS/shift-log.md`. Never delete the marker.
- `ok deadline none (finite list …)` — correct. Their natural end is the last tick, and a stuck run
  is red-flagged in the shift log and held for review.
- `refuse deadline` — an `Ending: open-ended` marker with no clock. Refuse to start, say so in one
  line, and point at Hunt, which asks for hours; never invent a number.

One deadline governs the whole shift: finite items first, the walkthrough soaks up the rest.

## 4. Arm the gate

Every check has passed and the work is known, so the shift begins here. Create the marker:

```bash
touch "$NS/.shift-armed"
```

Native Windows:

```powershell
New-Item -ItemType File -Force "$NS\.shift-armed" | Out-Null
```

**This, and nothing else, is what puts a session on shift.** Until it exists the punch list is an
ordinary to-do file: the clock-out gate holds nobody and hardhat's guards apply to no one, so a
session that writes items while planning still stops freely. Write it only after the preflight
returned zero. A marker left behind by a preflight that stopped early would put the next session on
a shift it never started.

### Bind this session — before any other tool

Immediately after writing `$NS/.shift-armed`, make this the next tool call on either host:

```bash
: nightshift-binding-probe
```

On native Windows, the immediate PowerShell probe is:

```powershell
$null = 'nightshift-binding-probe'
```

This harmless host-shell probe makes the hardhat record this conversation in `$NS/.shift-session`
and claim generation 1 in `$NS/.shift-lease` before item work or the watchman begins. Its
distinctive marker also makes a concurrent second Start fail explicitly if another session won the
atomic session-file claim. Do not read files, search, call MCP, or yield between the marker and the
probe: catch-all tool rules observe those calls, but passive tools cannot make the first session
claim. Never create or edit the lease directly.

The probe must execute cleanly with no hook denial or hook error. On native Windows this is also
the live check that the filesystem can make an atomic private session claim and lease. If it fails,
remove `$NS/.shift-armed`, run Stop, and use the stale-lease reset procedure in `start-hosts.md`;
do not begin item work or arm a watchman on an assumed claim.

### Codex identity checkpoint — before the watchman

Codex exposes the current task identity through hook payloads, not as a shell environment variable,
so this runs after the probe and before the watchman:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/start-preflight.sh" --project "$NIGHTSHIFT_WORKSPACE" --phase bind
```

Native Windows: the same script with `-Phase bind`. It classifies `$NS/.shift-session` line 1 with
`ns_codex_identity_kind` (native Windows: `Get-NSCodexIdentityKind` after
`Import-Module "$NIGHTSHIFT_PLUGIN_ROOT\lib\Nightshift.psm1" -Force`).

- `ok codex-identity resumable`, or `not-applicable` on another host — continue.
- `warn codex-identity missing` — continue with the fresh-session fallback and say plainly that
  same-thread recovery is unavailable until an identity is recorded.
- `refuse codex-identity` — stop the unattended start.
  Remove only the markers this start created (`$NS/.shift-armed` and its
  new `$NS/.shift-session`) and reset the lease with `ns_lease_reset_stale` in the same Bash call,
  so no hook call in between can bootstrap the aborted lease again. On native Windows,
  `Reset-NSStaleLease "$NS"` with no other command between marker removal and the reset. Append one
  failed-preflight line to `$NS/shift-log.md` and stop before the watchman or item work. Never
  pass the value to Codex, print it, or guess a replacement.

This capture-and-check is part of Start, not an owner instruction to remember. An attended session
that does not request an unattended shift remains unaffected.

## 5. Heads-up

Surface any still-unanswered entries in `$NS/parking-lot.md` (read-only) so the owner sees what the
last shift parked — printed, never waited on. Append a `shift started` line to `$NS/shift-log.md`.
The preflight rotates that journal itself when it grows past ~500 KB, into
`$NS/archive/<YYYY-MM-DD>/shift-log.md` (`date +%Y-%m-%d` on POSIX, `Get-Date -Format yyyy-MM-dd`
on native Windows). Only the mechanical journal auto-rotates — `snag-log.md` and `parking-lot.md`
are the owner's review material, and Archive files those on the owner's order.

## 6. Arm the night watchman

Each host arms its own; both read their cadence from the rules file, and each stands down on a
shift the other host owns. Unless the `ok watch-minutes 0 (watchman disarmed)` verdict says
otherwise, arm it in the background.

On Claude Code:

```bash
nohup "$NIGHTSHIFT_PLUGIN_ROOT/runtime/claude/watchman.sh" --project "$NIGHTSHIFT_WORKSPACE" >/dev/null 2>&1 &
```

On Codex:

```bash
nohup "$NIGHTSHIFT_PLUGIN_ROOT/runtime/codex/watchman.sh" --project "$NIGHTSHIFT_WORKSPACE" >/dev/null 2>&1 &
```

On Cursor:

```bash
nohup "$NIGHTSHIFT_PLUGIN_ROOT/runtime/cursor/watchman.sh" --project "$NIGHTSHIFT_WORKSPACE" >/dev/null 2>&1 &
```

On native Windows, start the same bundled PowerShell watchman for the active host:

```powershell
& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\start-watchman.ps1" `
 -Project "$NIGHTSHIFT_WORKSPACE" -HostName claude
# Codex uses: -HostName codex
# Cursor uses: -HostName cursor
```

It revives a session that DIES mid-shift — an API outage, a crash, a killed terminal — by spawning
a fresh session that resumes from the punch list. Every host stands down on done, a stop-work
order, or quitting time; per-host revival detail is in `start-hosts.md`. `STOP` remains the
stop-work order on every host, and the only stop a headless run can receive.

## 7. Work

Begin item 1 and follow the nightshift skill: one item at a time,
gate before each commit or artifact receipt, tick only after the item is complete, park don't ask,
leave pushing to the owner unless the punch list says otherwise. From here the clock-out gate owns the session — it will not
let you stop while any box is open.

Whenever an item answers a tool, a scan, or a report, write that source's baseline before the first
fix — once per source class — using the receipt templates in
`$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/receipt-templates.md`. Before a risky
cluster, write a checkpoint receipt naming the touched paths, the rollback ref, and the
verification plan. The model writes the receipt; no evidence helper is required, and Python never
is. Cited reports follow
`$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/cited-research.md` and
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/check-report.sh"` (native Windows:
`& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\check-report.ps1"`).

At clock-out the gate renders the morning receipt itself. When it reports
`JSON parser unavailable` in `$NS/shift-log.md`, write that one page by hand into
`$NS/receipts/morning-<YYYY-MM-DD>.md` from the Morning receipt block in
`$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/receipt-templates.md`, naming the shift id
when a policy carries one. Every shift leaves a receipt.
