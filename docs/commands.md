# Command reference

```text
/nightshift:setup      # scaffold .nightshift/ + propose quality gates (ask, never impose)
/nightshift:quality    # survey quality debt; choose review first or run directly
/nightshift:hunt       # compose tonight: pick ready shifts, set hours, add your scope
/nightshift:import-issues  # stage explicitly named GitHub issues onto the drafting table
# or write your items in the punch list by hand — one checkbox per task
#   item anatomy, with filled items: examples/overnight-webapp.md
/nightshift:start      # asks nothing: cuts what is queued, arms the site, works the list
/nightshift:status     # morning: what got done, what got parked, what got stuck
/nightshift:doctor     # diagnose the site: facts, warnings, classified next actions; never repairs
                       # optional follow-up: export a local support bundle (never uploaded)
/nightshift:stop       # pause now; open boxes stay open; deadline is preserved
/nightshift:reset      # drop runtime markers and the deadline; keep punch list and history
/nightshift:purge      # delete this project's .nightshift/; does not uninstall the plugin
/nightshift:archive    # file finished work under the archive root, .nightshift/archive/<YYYY-MM-DD>/ by default — shipped items, logs, handled snags; leftover contract stays
# you review the local commits or artifact receipts — push only in repository mode, or forbid pushing outright (one env line below)
```

Start asks nothing. It runs one native preflight —
`plugins/nightshift/runtime/start-preflight.sh`, or
`plugins\nightshift\runtime\windows\start-preflight.ps1` on native Windows — which prints one
verdict per line (`ok`, `warn`, `refuse`) and exits non-zero when the site must not arm. Those
sentences are identical on every host, so a scheduled run behaves like an interactive one. Detail
behind a host-specific verdict is in
[`references/hosts/`](../plugins/nightshift/skills/nightshift/references/hosts/).

Quality uses the same Guided or Automatic selection and Review first or Run directly launch modes
as Hunt. Both compose in the skill; the model plans. Copyable owner requests for each combination
are in [Shift modes](shift-modes.md). A review-first survey is read-only until the owner chooses what happens next: **fix now**
appends a Hunt work order then cuts and starts it, **draft for later** writes only to the drafting
table, and **ignore** writes nothing. Run directly composes that same work order, arms, and starts
the selected work without a second approval pause.

Those are Claude Code's slash spellings. In Codex or repository-connected ChatGPT, mention
Nightshift and ask naturally: “set up Nightshift,” “show me the ready-made shifts,” “run product
evolution for four hours,” “start the shift,” or “show shift status.” A normal ChatGPT scratch
conversation cannot affect the repository, so Setup redirects it to Codex before writing. The same
skills and `.nightshift/` files are used in persistent project workspaces.

For a custom timed objective, use Hunt in **Guided** mode and choose **Owner walkthrough**. Its
scope answer is required and becomes the objective verbatim; then set the hours and choose review
first or run directly. Automatic mode never selects this entry because the goal must come from the
owner rather than work-target discovery.

Automatic mode also skips the GitHub issue hunt in artifact mode. Imported drafts stay on the
drafting table until the work target is a matching git repository.
Automatic mode also skips the defect hunt in artifact mode.
Automatic mode also skips documentation drift in artifact mode.
Automatic mode also skips TODO and FIXME debt in artifact mode.
Automatic mode also skips coverage hunt in artifact mode.
Automatic mode also skips tooling quality-debt entries in artifact mode.

When the task root and Nightshift workspace differ, setup can create an explicit local link after
showing both absolute paths and receiving confirmation. The offline equivalent is:

```bash
plugins/nightshift/runtime/link-workspace.sh --host-root /absolute/task/root --workspace /absolute/workspace
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\link-workspace.ps1 `
  -HostRoot C:\absolute\task\root -Workspace C:\absolute\workspace
```

The target must already contain `.nightshift/`. Relative, missing, multiline, and symlink pointers
are rejected; Nightshift never searches for a workspace automatically.

Immediate pause, any time, without a model. `--project` is the folder you opened (task root);
Nightshift follows `.nightshift-link` when present. Do not omit `--project` — these helpers never
guess the current working directory.

```bash
plugins/nightshift/runtime/stop-shift.sh --project /absolute/task/root
plugins/nightshift/runtime/reset-shift.sh --project /absolute/task/root
plugins/nightshift/runtime/purge-workspace.sh --project /absolute/task/root \
  --confirm-path /absolute/workspace/.nightshift
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\stop-shift.ps1 -Project C:\absolute\task\root
plugins\nightshift\runtime\windows\reset-shift.ps1 -Project C:\absolute\task\root
plugins\nightshift\runtime\windows\purge-workspace.ps1 -Project C:\absolute\task\root `
  -ConfirmPath C:\absolute\workspace\.nightshift
```

Stop writes `STOP` and stands a verified watchman down. Hardhat stays until clock-out writes
`.nightshift/.ended`; Reset is the manual escape. The deadline is preserved. Reset also removes runtime
markers, the deadline, and leftover STOP. Purge does Reset, then deletes only that project's
`.nightshift/` after an exact `--confirm-path` match. None of them uninstall the plugin.

A panic `touch .nightshift/STOP` (POSIX) or `New-Item -ItemType File -Force .nightshift\STOP`
(native Windows PowerShell) still writes the stop-work order in the folder that contains
`.nightshift/` — not beside `.nightshift-link`. A STOP next to `.nightshift-link` is not
the order. That marker waits for the next Stop event or watchman wake; it does not disarm
immediately. On Claude Code, Escape
pauses the interactive session and its watchman reads that interrupt before reviving. Codex exposes
no equivalent owner-interrupt signal, so closing an interactive Codex session with open Items hands
the shift to its watchman.

When a paused Stop left an expired deadline, Start refuses to invent a new time budget. Write a
new UNIX epoch to `.nightshift/deadline`, or run Reset then Start.

When a shift is not where you think it is — wrong folder, broken `.nightshift-link`, leftover
`STOP`, watchman stood down, or a stale process rejected by the process lease — run
`/nightshift:doctor` on Claude Code or ask Nightshift to diagnose on Codex, then walk
[Troubleshooting](troubleshooting.md) before changing files. Doctor reports; it never repairs.
In artifact mode it also reports `artifact receipts N`, `latest artifact receipt` with the
filename of the most recently written receipt when any exist, and warns `artifact mode has ticked items but no receipts` when boxes
were ticked without `write-receipt`. It warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory, and offers a confirm action to replace it rather than write-receipt. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts.

A local support bundle from a terminal (never uploaded). Known sensitive fields
are omitted:

```bash
plugins/nightshift/runtime/export-support.sh --project .
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\export-support.ps1 -Project .
```

An artifact-mode completion receipt (refuses repository mode; rejects missing or empty outputs):

```bash
plugins/nightshift/runtime/write-receipt.sh --project . --item 'title' --verify 'checks' --output ./out.md
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\write-receipt.ps1 -Project . -Item 'title' -Verify 'checks' -Output .\out.md
```

Copy live artifact receipts into today's dated archive folder (leaves the live copies in place).
Missing or empty receipts create no dated receipts folder.

```bash
plugins/nightshift/runtime/archive-receipts.sh --project .
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\archive-receipts.ps1 -Project .
```

A cited research report against its source manifest:

```bash
plugins/nightshift/runtime/check-report.sh --project . --report ./report.md --manifest ./sources.tsv --output ./report.md
```

Native Windows:

```powershell
plugins\nightshift\runtime\windows\check-report.ps1 -Project . -Report .\report.md -Manifest .\sources.tsv -Output .\report.md
```

**Permissions: the night cannot click Allow.** An unattended shift freezes on a permission prompt,
and a watchman revival runs headless — a denied tool stays denied. For long runs,
`bypassPermissions` is the recommended mode, set in the project's `.claude/settings.local.json` so
revived sessions inherit it (`/nightshift:setup` offers this and writes it on a yes); the narrower
alternative is pre-allowing the punch list's own tools. nightshift's guards are hooks — they stay
armed in every permission mode, bypass included. Decline both and a mid-shift prompt costs the
night; that trade is the owner's.

On Codex, a committing unattended run uses `codex -a never -s danger-full-access`;
`workspace-write` protects `.git` and cannot create the per-item commits. The owner-defined
Nightshift guards remain active in either sandbox mode.

### Start it at a fixed time

```text
Claude Code: /nightshift:schedule
Codex: ask Nightshift to schedule the shift
```

It checks the things that would otherwise surprise you at 4am — that work is actually queued in the
punch list, that permissions won't stall a headless run, that nothing is registered twice — then
prints the launchd plist (macOS), crontab or systemd entry (Linux), or Task Scheduler XML (native
Windows) for this project and the one command that installs it. **It registers nothing itself.**

Two things it will tell you, worth knowing in advance: **the items must be in the punch list before
the scheduled time**, because a start works the list it finds and promotes nothing; and **a sleeping
machine runs nothing** — launchd defers a missed job to the next wake, cron loses it, and only
`pmset repeat wakeorpoweron` makes a Mac wake for it.

#### When you have no credit left

The moment you most want to schedule a run is often the moment your quota is gone — and then no
slash command works, because a command is read by the model. The generator underneath is plain
shell that spends no tokens and needs no session:

```bash
plugins/nightshift/runtime/schedule.sh --project . --preflight   # check both hosts; writes nothing
plugins/nightshift/runtime/schedule.sh --project . --at 04:05    # print the config + the install command
plugins/nightshift/runtime/schedule.sh --project . --at 04:05 --agent 'codex exec -s danger-full-access'
                                              # same entry, run by Codex instead of Claude
plugins/nightshift/runtime/schedule.sh --project . --at 04:05 --target systemd
                                              # print user .service/.timer; never runs systemctl
plugins/nightshift/runtime/schedule.sh --project . --list        # what is already registered for this project
plugins/nightshift/runtime/schedule.sh --project . --remove      # the command that unregisters it
```

Run it from a terminal, or copy the single file anywhere. It refuses a second entry for a project
that already has one, and identifies projects by path rather than folder name, so two checkouts
called `api` never collide. It cannot queue your work for you, though — that part has to be in the
punch list already. Preflight also fails `work mode is unset; Setup would propose artifact - a scheduled start will refuse to arm` when the mode file is missing and Setup would propose artifact.
It also fails `work target could not be resolved - a scheduled start will refuse to arm` when the recorded work target cannot be read.

Native Windows uses the token-free PowerShell generator:

```powershell
plugins\nightshift\runtime\windows\schedule.ps1 -Project . -Preflight
plugins\nightshift\runtime\windows\schedule.ps1 -Project . -At 04:05
plugins\nightshift\runtime\windows\schedule.ps1 -Project . -At 04:05 `
  -Agent 'codex exec -s danger-full-access'
plugins\nightshift\runtime\windows\schedule.ps1 -Project . -List
plugins\nightshift\runtime\windows\schedule.ps1 -Project . -Remove
```

It emits a current-user Task Scheduler definition with overlap prevention and `StartWhenAvailable`.
It does not wake the machine or run after logout as a stored-credential account; see
[Native Windows](windows.md).

One more appears in Claude Code's slash menu: `/nightshift:nightshift` is the method itself — how to
work an item, park a decision, keep a snag log, and run product evolution. The agent loads it on its
own whenever a shift is running, so you rarely invoke it directly.
