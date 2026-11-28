---
name: history-cleanup
description: Condense the project's Nightshift history into a short summary and detail files that keep every decision, rejection and open question still in force, then delete the condensed originals on the owner's yes.
license: MIT
metadata:
  internal: true
---

Review the history of the host-opened project. Old shifts leave many records behind: filed punch
lists, receipts, parking lots, snag logs, plan records, shift logs and morning pages. Read them,
decide what still matters, and write it down once, in two layers: a summary a person reads in a
few minutes, and detail files an agent opens when it works on that subject again. Then delete the
originals whose facts now live there.

## What the owner asks for

The owner says what they want in their own words, with the command or without it. Read the request;
there are no flags to parse.

- **Which records.** With no age given, the review covers every record on file. An age limits it to
  older records: "older than 10 days", "older than two months", "before March". Turn it into a date
  (today minus the age, or the date named), say that date in the report, and read only the shift
  folders and records from before it. Date each one by what it shows: the folder's date, the last
  line of its shift log, or the date Git recorded for the file when it is tracked. Newer records stay
  untouched and are not condensed.
- **Whether to ask before deleting.** By default the review proposes what can go and waits for the
  owner's answer. When the owner asks to apply it directly ("apply directly", "apply direct", "don't
  ask, just delete", or `--apply-direct` written after the command), that is the yes in advance for
  the originals this review condenses: delete them without proposing first, under the same rules
  below, and report what went.

Resolve the installed plugin root to an absolute `$NIGHTSHIFT_PLUGIN_ROOT` — `${CLAUDE_PLUGIN_ROOT}`
on Claude Code, `$PLUGIN_ROOT` on Codex when set, otherwise the absolute path this skill was
attached from (`skills/history-cleanup/SKILL.md`). Run every command below through
`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns"` — native Windows: `& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1"`
in the PowerShell tool, same verbs. `ns bind` prints the resolved workspace and `NS`; `ns path <key>`
prints where this workspace keeps a record, and `ns path --list` names every key.

## The two layers

**Summary** — the history index Archive already keeps, `history-index.md` at the archive root
(`ns path archive`). One index, never a second one. Archive's per-shift entries stay as they are;
the review adds a `## Condensed history` section above them. Its first line records what has been
condensed, so a later review knows where to start:

~~~markdown
Covers: <every record folder read, relative to the archive root, comma-separated, oldest first>
~~~

Then one short block per subject:

~~~markdown
### <subject>
Now: <the decision in force, in one or two sentences>
Why: <the reason that still holds>
Replaced: <what it superseded, or nothing>
Open: <the question still undecided, or none>
Detail: <a markdown link to history/<subject>.md>
~~~

A subject is a code area or a topic the owner would recognise (`clock-out gate`, `worktree runs`,
`release process`), named in lower-case words; its file name is that name with spaces as hyphens.
Pick subjects from the records, not from a fixed list.

**Detail** — `history/<subject>.md` beside the index. What an agent needs to act on the subject
later, and nothing else:

- each decision, newest first, with the date and the record it came from; a replaced decision stays,
  marked `replaced <date> by <the newer decision>`;
- options tried or rejected, each with the reason;
- what was verified and how (the command, the test, the evidence file);
- the commits, pull requests and releases that carry it;
- disagreements between records that nothing settled, quoting both sides in a line each.

Write facts, not narration. One fact appears once: the summary points at the detail, the detail
does not repeat the summary. Link each fact to its source record with a link relative to the detail
file (`../<folder>/receipts/…`), so the agent can open the original while it still exists.

## Find the records

Records live in more than one layout, depending on the workspace's age. Look in all of them and do
not stop at the first that exists:

- shift folders filed by Archive, laid out like the live site: `archive/<folder>/` and, in a
  workspace that keeps runs, `archive/<folder>/runs/<run>/` — punch list, `receipts/` (with the
  morning page), `inbox/` (parking lot, snag log), `run/` (shift log, shift policy);
- live runs: `runs/<run>/` — read their closed records only; open items, unanswered parking-lot
  entries and open snags stay live and are not condensed;
- single-shift folders from older layouts: `archive/<YYYY-MM-DD>/` and `archive/<YYYY-MM-DD>/run/`,
  which may hold `shipped.md`, `shift-log.md`, `parking-lot.md`, `snag-log.md`, the opportunity map
  and product research;
- plan records and planning decisions: `ns path plan-records`, `ns path decisions`;
- the history index itself, for the per-shift entries Archive wrote.

List what you found with a count and total size per kind before reading, so the receipt can state
the size before. Records the review does not reach this time stay where they are, untouched.

## Decide what stays

Keep, for every subject:

- every decision still in force, and every decision a later one replaced (in the detail, marked);
- every rejected option and its reason, so nobody proposes it again;
- every verification that a later change could break;
- every question no record answers, and every disagreement no record settles.

Drop: intermediate states a later record superseded within the same shift, text repeated across
records, progress chatter, usage tables, timestamps that carry no decision, and anything already
true of the code that the code or Git history shows plainly.

Where two records disagree and neither settles it, the summary says `Open:` and names both; never
pick one silently. Where a record is unreadable or a link inside it is broken, say so in the detail
and keep going; never guess what it said.

## Write

Write the detail files first, then the `## Condensed history` section of the index. When a subject's
file or block already exists, update it in place rather than adding a second.

Writing changes and deletes no original record. Deleting what was condensed is the next step, and
it waits for the owner.

## Delete what was condensed — only on the owner's yes

Once the two layers are written, propose the originals that can go. List each one by path with
one line: why it can go, and where its useful facts now live (`history/<subject>.md`, or "nothing
in it still applies"). Never propose a record of a live run, an unanswered parking-lot entry, a
snag with no disposition, or a record the review did not read.

Before asking, check whether each proposed record is tracked in Git (`git -C <its folder> ls-files
--error-unmatch <file>`, in the project repository or the receipts repository `ns path receipts-repo`).
When it is, say that Git's history is the undo. When it is not, say plainly that deleting it cannot
be undone.

Then ask the owner, and wait: all, some (named), or none. Silence or an unclear answer is none.
When the owner asked to apply directly, skip the question: every record you would have proposed is
approved, and the report lists each deleted path with whether Git can bring it back. An unattended
run deletes only when its order says to apply directly; otherwise it writes the proposal into the
report and stops there.

Delete exactly the approved paths and nothing else, and only while no shift is armed in this
workspace. Where the owner approved a whole shift folder, run `ns retain-history` first: when its
preview lists only approved folders, `ns retain-history --apply` deletes them; otherwise delete each
approved path by name. Never delete by pattern or loop over a listing; name each path.

Then repoint every link that pointed at a deleted record, in the index, the detail files and the
records that remain:

- in the index or a remaining record, point it at the detail file that now holds the facts;
- in a detail file, replace the link with the source's name as plain text and `(deleted <date>)`.

Search for the deleted paths afterwards: no link may still point at one. Report what was deleted,
what was kept, and every link changed.

## Later reviews

When the index already has a `## Condensed history` section, read only the record folders its
`Covers:` line does not name, plus closed records of live runs that have closed since. Leave the
covered originals unread; their facts are already in the two layers.

With nothing new, change nothing: no file is rewritten, not even to refresh a date, and the report
says the history is up to date.

With new records, merge their facts into the existing subjects, or add a subject when a new topic
appears:

- a newer decision becomes the summary's `Now:`; the detail file adds it at the top and marks the
  older one `replaced <date> by <the newer decision>`, which stays;
- a new rejection, verification, commit or release joins its list in the detail;
- a new record that settles an `Open:` question moves it to a decision; one that contradicts a
  decision without settling it becomes an `Open:`;
- add the new folders to `Covers:`.

Touch only the subjects the new records speak to: every other block and detail file stays byte for
byte as it was. Then propose deleting the newly condensed originals, as above.

## Sharing

Whether the condensed history is shared follows Git, not a setting. The shipped
`.nightshift/.gitignore` keeps `archive/history-index.md` and `archive/history/` private to each
clone; a team that wants to share them deletes those lines. Read `ns path gitignore` and say which
applies.

## Report

Print, in a few lines: the age limit and its date when the owner gave one, the subjects written, the open questions and disagreements, and the size of
the records read against the size of the summary and detail files together (`wc -c` on POSIX,
`(Get-Item).Length` on native Windows). The two layers should be much smaller than what they
replace; when they are not, condense again before reporting.
