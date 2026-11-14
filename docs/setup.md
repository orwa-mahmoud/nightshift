# Setup

Run `/nightshift:setup` in the project you want Nightshift to work on. It prepares the project and
asks at most four questions, so every shift after it runs with your preferences. Run it again at
any time: it shows your current values and changes only what you name.

## What it creates

Setup writes a `.nightshift/` folder in your workspace with the files every shift uses: the
**punch list**, the **drafting table**, the **parking lot**, the **snag log**, the **shift log**,
and **`rules.json`**, your one settings file. A file you already have is kept exactly as it is, so a
second run is a safe repair.

Run state stays out of your project's history. When `.nightshift/` sits inside a Git repository,
Setup adds it to `.gitignore`.

## The questions

Setup asks these in order, skips any whose answer is already clear, and never splits one into
several turns.

| # | Question | When it is asked |
| --- | --- | --- |
| 1 | **Work target:** which folder or repository the shift changes. | Only when it is ambiguous, such as a folder holding several repositories. |
| 2 | **Checks:** the commands that verify the work. | When there is code to check. Setup detects your stack and proposes its commands. |
| 3 | **Defaults:** every other choice, on one screen. | Always. |
| 4 | **Copy-in files:** ignored files the tests need in a shift worktree, such as `.env.test`. | Only when you turn on shift worktrees. |

### Checks

Setup detects your stack, monorepos included, and proposes the commands that verify it. It says
where each proposal came from, and a stack of your own in the catalog replaces the shipped one.
Answer with:

- **accept** to use the proposal as it is,
- **edit** to add, remove or replace commands with your own (any shell command is a valid check), or
- **none** to run shifts without automated checks.

The accepted commands go in the `## Gates` block of the punch list, where you can edit them at any
time.

### Defaults

Every remaining choice is on one screen. Answer **accept all**, or name what to change in the same
reply, such as "worktree yes, 6 hours, deny sudo".

| Setting | Default | What it decides |
| --- | --- | --- |
| Receipts repo | no | A local-only Git repository inside `.nightshift/`, so every punch-list change has history. It is never pushed and never touches your project's history. |
| Shift worktree | no | Each shift works in its own worktree and branch, so your checkout and uncommitted edits stay untouched. Setup proposes the install command to run in it, such as `npm ci`. |
| Site inspection | hourly | How often the heavier checks run, such as coverage or dead-code scans. Shown only when you kept checks. |
| Verification profile | `fast` | When the checks run: `fast` never, `balanced` once before clock-out, `strict` before every tick and at the end, `custom` on your own cadence. |
| Typical hours | none | The hours a composed shift gets when you name none. |
| Execution | `run-direct` | Whether a composed shift starts at once, or `review-first` shows it for your approval. |
| Tooling policy | `auto-add` | Whether the agent may add standard development tools the project selects, or holds back with `review-missing` or `existing-tools`. |
| Recovery | `host-default` | How a stalled session is revived: under your host's own permissions, or by restoring a recorded Codex sandbox. |
| Elevation | all allowed | `sudo`, containers, global packages, daemons and external logins. Name any to deny. |
| Evidence | check `off`, review `off` | Whether a missing evidence file blocks a tick, what happens when evidence cannot be produced, and whether the agent reviews its own evidence. |

In a plain folder without Git, the screen shows only the lines that apply there: receipts repo,
typical hours, execution, recovery and evidence.

The same screen also offers what this version brings, one line each: settings added since your
`rules.json` was written, a ready-made rule profile to apply, and moving an older `.nightshift/`
layout to the current one. Each is applied only on your yes.

## Permissions

An unattended shift cannot answer permission prompts, so you set the host's permissions yourself
before leaving a shift alone. Setup never changes them, and Nightshift adds no restriction beyond
what the host allows unless you set one in `rules.json`.

## After setup

Setup ends with a summary: where the state lives, the work target, the checks it wrote, and the
defaults now in `rules.json`. From there, plan in the [plan room](plan-room.md#the-plan-room), or
say "improve this project for 5 hours" and Hunt composes a shift from the catalog and starts it.

Change any setting later with `/nightshift:customize`, by editing `.nightshift/rules.json`, or by
asking in plain words. The hooks read the file on every tool call, so an edit applies at once.
[Owner knobs](knobs.md#owner-knobs) lists every setting.

---

[The plan room](plan-room.md#the-plan-room) · [Owner knobs](knobs.md#owner-knobs) · [Documentation index](README.md#documentation)
