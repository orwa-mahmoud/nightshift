# The morning receipt

Use this page for the compact clock-out summary. For live item progress and measured token usage,
read [Receipts and token usage](receipts.md#receipts-and-token-usage). After reviewing, [archive the shift](archive.md#archive-and-continue)
to preserve its receipts and evidence for later work.

Everything else in `.nightshift/` is a working file: the punch list changes as items tick, the
parking lot empties as decisions get read, the ledger keeps growing. The receipts index is the live,
per-item view while the shift runs. The morning receipt is written once, at clock-out, and answers
two questions: how did the night go, and what should the owner do next. It renders Markdown from
records that already exist — the evidence ledger, an accepted `shift-policy.json`, `punch-list.md`,
the usage marks under `usage/`, `shift-log.md`, `parking-lot.md`, `snag-log.md`, and the work
target's history — and invents nothing. A check that did not run is never described as passed, and
a model's own claim about its work is never upgraded into proof; only a ledger record, a commit, or
a receipt earns a line in the receipt. Shift identity and every other policy-derived fact come only
from a policy that validates. A missing file is `absent`; a file that is present but unreadable or
fails the schema is `malformed`. The rest of the page still renders from the punch list, the ledger,
and the other working files. A malformed policy never blocks STOP, the deadline, or clock-out.

`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" morning-receipt [--view owner|reviewer|release|artifact] [--out PATH]`
(native Windows: `ns.ps1 morning-receipt`) renders it on demand. The clock-out gate
also writes the owner view automatically, best effort, to
`.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md`, or
`.nightshift/receipts/morning-<YYYY-MM-DD>.md` when the shift wrote no policy and so has no id —
a failed render never blocks the shift from ending, and `/nightshift:archive` moves the file with
the rest of the night's receipts. Both the live receipts index and the archived one link every
morning page in their folder above the item table, so the summary is one click from the per-item
view.

## What each section means

The page opens with a `Receipts:` line linking the index, `[index](./README.md)`. Directly under
that, a `Policy record:` line names `accepted`, `absent — the shift wrote no policy`, or
`malformed — the policy file is present but unreadable or fails the schema`. Each section below
carries its `handoff.sections` id in brackets.

1. **How it ended** (`shift`) — the shift id, host, and work target; when it started and ended, both
   in UTC with the zone written out; how it ended (done, a stop-work order, quitting time, or a
   stall); how many items were open versus ticked; commits or artifact receipts; and the policy
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
2. **Time and tokens** (`usage`) — the whole shift, from the arming mark to the end: the span in
   UTC, working time, paused time split by the reason each pause was recorded under (an owner stop
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
10. **Unsupported / unmeasured** (`unsupported`) — surfaces the ledger could not put through the
    usual pass/fail path: human-only judgment calls, unsupported checks, and anything left
    unmeasured.
11. **Next step** (`next`) — the open items, the single opportunity marked `Status: building`
    during a product-evolution or owner-walkthrough shift, and the exact next action from the last
    handover line in the shift log.

Any section with nothing to report is left out entirely rather than printed empty. A `fast` shift
whose policy chose `none` and left no ledger renders no Baseline or What changed section, and its
`Verified:` line reads exactly `Verified: none — verification level none (owner)` — the absence of
checks is stated, not implied by a missing section.

## Which view is for whom

- **owner** (the default) — every section above, in that order. Read this one first.
- **reviewer** — Review first, Baseline and What changed, with every locator intact, for someone
  re-running the verification rather than trusting the tick.
- **release** — How it ended plus a What changed narrowed to regressions: a release decision needs
  to see the regression count confirmed at zero, not infer it from an empty table.
- **artifact** — every section except Baseline and What changed, for a persistent-folder shift with
  no repository behind it. Commits become receipts and no git terminology appears.

`handoff.sections` picks and orders sections by the ids above for any view; an empty list keeps
the view's own order. All four views read the same underlying records, so none of them can
disagree with another — they only differ in which sections they show.

## Determinism

Digests throughout are sha256, hex-encoded. Every comparison row cites the ledger record id and
locator behind it, and every other line comes from a named record — nothing in the receipt lacks a
source. Timestamps are UTC (`%Y-%m-%dT%H:%M:%SZ`) and honor `NIGHTSHIFT_EVIDENCE_NOW` in tests. The
bash and PowerShell renderers produce byte-identical Markdown from the same records, and the bash
side produces the same bytes whether it reads JSON with `jq` or its `python3` fallback.

---

[Review the underlying evidence](evidence-capabilities.md#reviewing-a-shift) · [Documentation index](README.md#documentation)
