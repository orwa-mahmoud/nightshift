# The morning receipt

The morning receipt is the one page you read after a shift. It is written once, at clock-out, and
answers two questions: how did the shift go, and what should you do next. Item progress and token
usage live in the [receipts](receipts.md#receipts-and-token-usage); this page summarizes them and
links each item to its receipt.

It is built only from records the shift left: the evidence ledger, the shift policy, the punch
list, the shift log, the parking lot, the snag log, and the work target's history. It invents
nothing. A check that did not run is never described as passed, and the agent's own claim about its
work never counts as proof. A record that is missing reads `absent`; one that cannot be read reads
`malformed`, and the rest of the page still renders.

The clock-out gate writes it to `.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md`, linked
from the top of the receipts index. `ns morning-receipt [--view owner|reviewer|release|artifact]`
renders it again on demand, and `/nightshift:archive` files it with the shift.

## What each section means

The page opens with a `Receipts:` line linking the index, `[index](./README.md)`. Directly under
that, a `Policy record:` line names `accepted`, `absent — the shift wrote no policy`, or
`malformed — the policy file is present but unreadable or fails the schema`. Each section below
carries its `handoff.sections` id in brackets.

1. **How it ended** (`shift`) — the shift id, host, and work target; when it started and ended, in your
   local time with its offset; how it ended (done, a stop-work order, quitting time, or a
   stall); how many items were open versus ticked; commits or artifact receipts; with
   `receipts.evidence.fileMap` on, a `Files:` line with the shift map's totals; and the policy
   that actually ran — verification level, tooling policy, and every elevation allowance with its
   provenance. The start is the arming mark, or the policy's `createdAt` when the shift kept no
   usage marks, and commits are counted from that moment; the end is when the clock-out gate
   closed the shift. Three lines always appear here, in this order: `Verified:` names what ran
   green and by which command, `Disabled by owner:` names the checks the chosen verification level
   skipped, and `Unavailable:` names any tool or source the ledger marked unavailable. A disabled
   check is never described as a passed one, and the owner is credited with disabling a check only
   when a shift policy set `verificationLevel` to `none`. A shift that wrote no policy runs on the
   built-in floor: a `Gates:` line names the
   commands the punch list's `## Gates` section asked for, `Verified:` reads
   `none — no shift policy was written`, and `Disabled by owner:` reads `none`. A present but
   unreadable or schema-failing policy is named as malformed on both the `Policy record:` line and
   `Verified:`.
2. **Time and tokens** (`usage`) — the whole shift, from the arming mark to the end: the span, working time, paused time split by the reason each pause was recorded under (an owner stop
   or Esc, a usage-limit wait, a revived session), and wall time. The reasons add up to the paused
   total. Below that, the host's token totals by kind in its own counting, with one sentence on
   which kinds already contain which. A kind the host does not report reads `unavailable`; a
   measurement the owner turned off (`receipts.usage` or `receipts.duration`) reads `off`. Nothing
   is converted to a price.
3. **Items** (`items`) — one line per punch-list item with its state, linked to its item receipt
   where that file exists. The item's own cost, sessions, checks and story live there; this page
   does not copy the per-item table.
4. **Review first** (`review`) — in repository mode, the three largest changes of the shift, ranked
   by lines and then files from their commits. Each commit is charged to the item whose span it
   landed in; a commit outside every item's span stands on its own line. Then the one command that
   shows the whole range, `git log --stat <first>^..<last>`. In artifact mode it states that it
   does not apply.
5. **Interruptions** (`interruptions`) — what the runtime wrote into the shift log since the shift
   started: watchman revivals and resume attempts, API failures, stalls, usage-limit waits, and
   how the shift was stopped.
6. **Decisions for you** (`parked`) — every decision still waiting in the parking lot, in full:
   wrapped lines are joined, never cut, with the default chosen so work could continue and how to
   roll it back when the entry records them. Answered entries, `Filed:` pointers and runtime
   notices are left out.
7. **Found but not fixed** (`snags`) — this shift's snag-log entries, dated on or after the day it
   started, whose disposition is not `fixed`, each with its disposition and reason. An entry with
   no disposition reads `open`.
8. **Baseline** (`baseline`) — one line per originating source (the tool, its exact command, and
   its environment) with that source's environment digest and raw-output digest, so a reviewer can
   tell exactly what ran and against what versions.
9. **What changed** (`changed`) — the comparison table: every finding classified against its
   baseline as new, cleared, unchanged, regressed, unavailable, a rejected duplicate, parked, or
   human-only, then one line per fix naming the item, its commit or receipt, how to re-verify it,
   and what the same source reported afterward. A tool that failed or went unavailable mid-shift is
   reported exactly that way — never folded into the cleared count.
10. **Architecture** (`architecture`) — with `receipts.evidence.architecture` on, the shift's
    diagram as it was left, linked, and each item whose receipt says `Diagram: updated — …`, with
    what it changed.
11. **Unsupported / unmeasured** (`unsupported`) — surfaces the ledger could not put through the
    usual pass/fail path: human-only judgment calls, unsupported checks, and anything left
    unmeasured.
12. **Next step** (`next`) — the open items, the single opportunity marked `Status: building`
    during a product-evolution or owner-walkthrough shift, and the exact next action from the last
    handover line in the shift log.

Any section with nothing to report is left out entirely rather than printed empty. A `fast` shift
whose policy chose `none` and left no ledger renders no Baseline or What changed section, and its
`Verified:` line reads exactly `Verified: none — verification level none (owner)` — the absence of
checks is stated, not implied by a missing section.

## Which view is for whom

- **owner** (the default) — every section above, in that order. Read this one first.
- **reviewer** — Review first, Baseline, What changed and Architecture, with every locator
  intact, for someone re-running the verification rather than trusting the tick.
- **release** — How it ended plus a What changed narrowed to regressions: a release decision needs
  to see the regression count confirmed at zero, not infer it from an empty table.
- **artifact** — every section except Baseline, What changed and Architecture, for a
  persistent-folder shift with no repository behind it. Commits become receipts and
  no git terminology appears.

`handoff.sections` picks and orders sections by the ids above for any view; an empty list keeps
the view's own order. All four views read the same underlying records, so none of them can
disagree with another — they only differ in which sections they show.

## Review it in the plan room

The page tells you what needs a decision; the plan room is where you make them. Open it with
`/nightshift:plan`. Entering lists the latest morning page and the
receipts index, every parked decision and snag still open, and every item still open or stopped. The
agent walks you through them one at a time and writes each answer where it belongs: ` · answered:`
on a parked decision, a disposition on a snag, and a drafted item for work to carry into the next
shift. Nothing is written without your answer, and the punch list stays yours to edit. After
Archive, the review reads what Archive left live.

## Every line has a source

Every comparison row cites the ledger record behind it, and every other line comes from a named
record. Times are in your local time with its offset, such as `2026-10-08 07:12:05 (UTC+04:00)`. The
page reads the same on macOS, Linux, and native Windows.

---

[Review the underlying evidence](evidence-capabilities.md#reviewing-a-shift) · [Documentation index](README.md#documentation)
