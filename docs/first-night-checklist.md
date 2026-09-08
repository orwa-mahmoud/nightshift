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
- **Know the host boundary.** The supported hosts' Stop hooks reject early clock-out, but recovery
  signals differ. Claude Code observes Escape and clean session ends. Codex SessionEnd pauses
  recovery; a crash without that event can be recovered. Cursor distinguishes IDE conversations
  from resumable CLI sessions. Do not treat closing a session as a crash test. On native Windows,
  the recorded process is identified by PID plus UTC start time.
- **Reopen a recovered thread only to inspect or interact.** The headless worker continues against
  the punch list without being watched, but a stale Claude Code or Codex panel cannot display its
  appended turns. Do not continue in that unchanged panel while recovery may still be working; the
  process lease fences its tool calls. See the
  [recovery handoff and upstream limitation](how-it-works.md#reopening-a-revived-thread).
- **Leave pushing for morning.** Keep the default local-only commits, review the diff and receipts,
  then push or open a pull request yourself. In artifact mode, review the output files and the
  shift report, plus any source, checkpoint, or optional item receipts. Use the
  [evidence review guide](evidence-capabilities.md#reviewing-a-shift) for receipt diagnostics and
  [Archive and continue](archive.md#archive-and-continue) after review.

The emergency stop is always available from the Nightshift workspace — the folder that
contains `.nightshift/`, not a linked task root:

```sh
touch .nightshift/STOP
```

Native Windows: `New-Item -ItemType File -Force .nightshift\STOP`.

See [Owner knobs](knobs.md#owner-knobs) for the exact rule and notification settings,
[Shift modes](shift-modes.md#shift-modes) for copyable Hunt requests,
[Command reference](commands.md#command-reference) for setup, start, hunt, import-issues, status, doctor, stop, and archive, and
[Troubleshooting](troubleshooting.md#troubleshooting) if the site is not where you expect.

---

[Run your first shift](../README.md#your-first-shift) · [Documentation index](README.md#documentation)
