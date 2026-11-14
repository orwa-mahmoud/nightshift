# First-night safety checklist

Go through this once before you leave a shift running on its own.

- **Watch the first shift.** Run one small shift while you watch it. Check that your checks pass,
  that the work lands as commits (or as receipts under `.nightshift/receipts/` in a plain folder),
  and that the shift ends only after its boxes are ticked. A Hunt or Quality shift that starts
  straight away counts too: watch its first run.
- **Set permissions on purpose.** An unattended shift cannot answer permission prompts. Allow only
  what the work needs, or choose full access knowingly. Nightshift's deny rules add boundaries on
  top; they are not a sandbox.
- **Try the stop before you sleep.** From another terminal, in the folder that holds
  `.nightshift/`, run `touch .nightshift/STOP` (native Windows:
  `New-Item -ItemType File -Force .nightshift\STOP`). The shift should end at its next stop, with
  unfinished boxes still open. Delete the STOP file before the next shift.
- **Decide how a stuck run ends.** By default a stalled shift is held and flagged for you. Set
  `stallMax` to clock out after a number of stuck attempts, and give open-ended work a deadline.
- **Test your notification.** `notifyCommand` runs your own shell command. Run it yourself first.
- **Test recovery with a real failure.** Closing a session on purpose is not a crash: on Codex it
  pauses recovery. The watchman revives sessions that die or stall on an API error.
- **Follow a revived shift from its receipts.** A revived session works headless. The old chat
  panel cannot show its new turns, so read progress with `/nightshift:status` and the receipts
  instead of typing into that panel. [Reopening a revived thread](how-it-works.md#reopening-a-revived-thread)
  explains why.
- **Push in the morning.** Commits stay local unless your punch list says otherwise. Review the diff
  and the receipts, then push or open a pull request yourself. Then
  [archive the shift](archive.md#archive-and-continue).

The stop is always available from the folder that holds `.nightshift/`:

```sh
touch .nightshift/STOP
```

[Setup](setup.md#setup) · [Command reference](commands.md#command-reference) ·
[Troubleshooting](troubleshooting.md#troubleshooting) · [Documentation index](README.md#documentation)
