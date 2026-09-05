# First-night safety checklist

Use this once before leaving Nightshift unattended in a project.

- **Start attended.** Run one small shift while watching it. Confirm the proposed gates pass, one
  item becomes one reviewable commit in repository mode, or its own section in
  `.nightshift/shift-report.md` in artifact mode, and the shift ends only after its box is
  ticked.
  Hunt or Quality that start immediately write the same binding probe and arm the same watchman —
  watch that first run too, even if you never invoked Start.
- **Choose permissions deliberately.** Pre-allow only what the work needs, or explicitly accept the
  unattended full-access option. Nightshift's owner-defined deny rules still matter; they are not a
  sandbox and do not replace reviewing the agent's permissions.
- **Prove STOP before sleeping.** From another terminal, in the folder that contains
  `.nightshift/` (not beside `.nightshift-link`), run `touch .nightshift/STOP` on POSIX or
  `New-Item -ItemType File -Force .nightshift\STOP` in native Windows PowerShell, then confirm the
  next stop attempt ends the shift while unfinished boxes remain open. Remove the test STOP file
  and start a fresh shift afterward.
- **Decide how stalls should end.** The default holds and flags a stalled run. Set `stallMax` only
  if you prefer an automatic clock-out after a fixed number of stuck attempts; always use a
  deadline for open-ended work.
- **Test notifications if configured.** `notifyCommand` is unrestricted owner-provided shell. Run
  it yourself first and remember it can access the network if your command does.
- **Know the host boundary.** Both hosts' Stop hooks mechanically reject an early clock-out and
  both watchmen target the recorded session. Recovery evidence differs: Claude Code records Escape
  and clean session ends; Codex does not, so do not treat closing a live Codex session as a crash
  test. On native Windows the same Stop and watchman contracts apply through PowerShell; a recorded
  process is identified by PID plus UTC start time.
- **Reopen a recovered thread only to inspect or interact.** The headless worker continues against
  the punch list without being watched, but a stale Claude Code or Codex panel cannot display its
  appended turns. Do not continue in that unchanged panel while recovery may still be working; the
  process lease fences its tool calls. See the
  [recovery handoff and upstream limitation](how-it-works.md#reopening-a-revived-thread).
- **Leave pushing for morning.** Keep the default local-only commits, review the diff and receipts,
  then push or open a pull request yourself. In artifact mode there is no work-target git history:
  review `$NS/receipts/` instead (Doctor names the most recently written file). Doctor warns `artifact receipts path is not a usable directory` when that path exists but is not a usable directory. Start, Hunt, Quality, and Schedule refuse when that path is unusable rather than begin a notes-folder night that cannot land receipts. Archive copies those
  files with `runtime/archive-receipts.sh` (native Windows: `runtime/windows/archive-receipts.ps1`)
  into the dated folder and leaves the live copies in place. Missing or empty receipts create no dated receipts folder.

The emergency stop is always available from the Nightshift workspace — the folder that
contains `.nightshift/`, not a linked task root:

```sh
touch .nightshift/STOP
```

Native Windows: `New-Item -ItemType File -Force .nightshift\STOP`.

See [Owner knobs](knobs.md) for the exact rule and notification settings,
[Shift modes](shift-modes.md) for copyable Hunt requests,
[Command reference](commands.md) for setup, start, hunt, import-issues, status, doctor, stop, and archive, and
[Troubleshooting](troubleshooting.md) if the site is not where you expect.
