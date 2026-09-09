# The morning receipt

Use this page for the compact clock-out summary. For live item progress and measured token usage,
read [Receipts and token usage](receipts.md#receipts-and-token-usage). After reviewing, [archive the shift](archive.md#archive-and-continue)
to preserve its report and evidence for later work.

Everything else in `.nightshift/` is a working file: the punch list changes as items tick, the
parking lot empties as decisions get read, the ledger keeps growing. The morning receipt is the
one file meant to be read once, cover to cover, over coffee. It renders Markdown from records that
already exist — the evidence ledger, an accepted `shift-policy.json`, `punch-list.md`,
`parking-lot.md`, `shift-log.md`, and the receipts index — and invents nothing. A check that did not run is never
described as passed, and a model's own claim about its work is never upgraded into proof; only a
ledger record, a commit, or a receipt earns a line in the receipt. Shift identity and every other
policy-derived fact come only from a policy that validates. A missing file is `absent`; a file
that is present but unreadable or fails the schema is `malformed`. The rest of the page still
renders from the punch list, the ledger, and the other working files. A malformed policy never
blocks STOP, the deadline, or clock-out.

`"$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" morning-receipt [--view owner|reviewer|release|artifact] [--out PATH]`
(native Windows: `ns.ps1 morning-receipt`) renders it on demand. The clock-out gate
also writes the owner view automatically, best effort, to
`.nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md`, or
`.nightshift/receipts/morning-<YYYY-MM-DD>.md` when the shift wrote no policy and so has no id —
a failed render never blocks the shift from ending, and `/nightshift:archive` moves the file with
the rest of the night's receipts.

## What each section means

The page opens with a `Receipts:` line: `[index](./README.md)`, then one relative link per
ticked item, `[NN. full title](./NN-slug.md)`, in punch-list order. Directly under that, a
`Policy record:` line names `accepted`, `absent — the shift wrote no policy`, or
`malformed — the policy file is present but unreadable or fails the schema`.

1. **Shift** — the shift id, host, and work target; when it started and ended and how it ended
   (done, a stop-work order, quitting time, or a stall); how many items were open versus ticked;
   commits or artifact receipts; and the policy that actually ran — verification level, tooling
   policy, completion mode, and every elevation allowance with its provenance. Three lines always
   appear here, in this order: `Verified:` names what ran green and by which command,
   `Disabled by owner:` names the checks the chosen verification level skipped, and
   `Unavailable:` names any tool or source the ledger marked unavailable. A
   disabled check is never described as a passed one, and the owner is credited with disabling a
   check only when a shift policy set `verificationLevel` to `none`. A shift that wrote no policy
   runs on the built-in floor: a `Gates:` line names the commands the punch list's `## Gates`
   section asked for, `Verified:` reads `none — no shift policy was written`, and
   `Disabled by owner:` reads `none`. A present but unreadable or schema-failing policy is
   named as malformed on both the `Policy record:` line and `Verified:`.
2. **Baseline** — one line per originating source (the tool, its exact command, and its
   environment) with that source's environment digest and raw-output digest, so a reviewer can
   tell exactly what ran and against what versions.
3. **What changed** — the comparison table: every finding classified against its baseline as new,
   cleared, unchanged, regressed, unavailable, a rejected duplicate, parked, or human-only, then
   one line per fix naming the item, its commit or receipt, how to re-verify it, and what the same
   source reported afterward. A tool that failed or went unavailable mid-shift is reported exactly
   that way — never folded into the cleared count.
4. **Parked** — decisions added to the parking lot this shift, each with the default chosen so
   work could continue and how to roll that default back if the owner disagrees.
5. **Unsupported / unmeasured** — surfaces the ledger could not put through the usual pass/fail
   path: human-only judgment calls, unsupported checks, and anything left unmeasured.
6. **Next** — the exact next action, taken from the punch list's open items and, during a long
   product-evolution or owner-walkthrough shift, the single opportunity marked `Status: building`.

Any section with nothing to report is left out entirely rather than printed empty. A `fast` shift
whose policy chose `none` and left no ledger renders only the Shift section, and its `Verified:`
line reads exactly `Verified: none — verification level none (owner)` — the absence of checks is
stated, not implied by a missing section.

## Which view is for whom

- **owner** (the default) — every section above. Read this one first.
- **reviewer** — sections 2 and 3 only, with every locator intact, for someone re-running the
  verification rather than trusting the tick.
- **release** — section 1 plus a section 3 narrowed to regressions: a release decision needs to
  see the regression count confirmed at zero, not infer it from an empty table.
- **artifact** — sections 1, 4, 5, and 6, for a persistent-folder shift with no repository behind
  it. Commits become receipts and no git terminology appears.

All four views read the same underlying records, so none of them can disagree with another — they
only differ in which sections they show and how much detail survives inside them.

## Determinism

Digests throughout are sha256, hex-encoded. Every table row cites the ledger record id and
locator behind it — nothing in the receipt lacks a source record. Timestamps are UTC
(`%Y-%m-%dT%H:%M:%SZ`) and honor `NIGHTSHIFT_EVIDENCE_NOW` in tests. The bash and PowerShell
renderers produce byte-identical Markdown from the same ledger, and the bash side produces the same
bytes whether it reads JSON with `jq` or its `python3` fallback.

---

[Review the underlying evidence](evidence-capabilities.md#reviewing-a-shift) · [Documentation index](README.md#documentation)
