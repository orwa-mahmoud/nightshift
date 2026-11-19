# A first shift on align-cli, with its decisions imported

One plan, one attended shift, two items on align-cli, a public open-source CLI. The planning
decisions and the two parked decisions were then read back by `align connect nightshift`, so this
receipt also shows what a shift's paperwork looks like to another tool.

## Outcome

- **2 of 2 items completed** in 32 minutes of working time, one commit each, failing test first.
- **Merged:** [aligndottech/align-cli PR #690](https://github.com/aligndottech/align-cli/pull/690)
  squash-merged as [f576995](https://github.com/aligndottech/align-cli/commit/f5769957d7ed856411d437d4754c443323f6117a). The two item commits stay reviewable on the pull request.
- **Gates passed once on the final tree:** lint, typecheck, 10,377 tests and the coverage run, all
  green. They ran by hand before clock-out, not per item. See "Found" below for why.

## What was planned

The plan room took the owner's request ("strip commit trailers like `Co-Authored-By` and
`Claude-Session` from a commit's reason") and first checked it against the code. That changed the
request in a useful way:

- There was no stored reason to strip. The reason is derived on read, so the plan strips there and
  leaves the stored text alone. That matched a decision the project had already made in an earlier
  pull request, which the plan room found and cited.
- The owner's rule ("a `Key: value` line in the last paragraph") would have broken two behaviours
  existing tests pin, so the plan room proposed four tightenings and two exemptions. The owner
  accepted them.

## Item receipts

All times UTC on 2026-11-19.

- `16:10` · [fix(ask): strip trailing trailer lines from the stated reason](https://github.com/aligndottech/align-cli/pull/690/commits/353f774c67d05a5f78add4fe39faf8d797d2932f)
- `16:25` · [fix(ask): drop unlisted trailer keys from the quote under an ask row](https://github.com/aligndottech/align-cli/pull/690/commits/512b8ceb5f4982ac3fda4cf875b9d52930d4f996)

## Morning

Two decisions were parked, each with the default the agent chose and a rollback line:

1. **Apply the rule to git commits only.** The agent measured the plan as written against a copy of
   a real 3,817-decision graph: it would have changed 371 of 486 PR quotes and 1,208 of 1,991 ticket
   quotes, whose last lines (`Status: merged`) are content. Restricted to commits, 4 quotes changed.
   Answered: accept the default.
2. **`See:` and `Ref:` lines ending a commit are stripped from the quote.** They fit the agreed rule
   but hold links. Answered: accept the default.

Nothing was reworded in the morning. The parking lot was answered and the shift archived.

## What align imported

`align connect nightshift` on the archived workspace imported 11 decisions: the 2 answered
parking-lot entries and 9 `Decided`/`Rejected` lines from the plan record, including
`Rejected: strip at import, before the summary is stored (option B)` with its reason. Nothing open
was imported.

The import as it ran on the archived workspace (align-cli 0.89.0, a fresh local graph):

```text
Found 11 items from nightshift

SOURCE                                          TITLE
nightshift://parking-lot/eaf823c088a07227       The trailer rule is applied to stored git commit
nightshift://parking-lot/69cdde97aa420d45       `See:` and `Ref:` lines that end a commit messag
nightshift://plan-record/633ca23a8451fe96       the owner's rules
nightshift://plan-record/9feccb0915c03ef8       strip when the reason is derived (option A)
nightshift://plan-record/5c4801f9e6485697       Rejected: strip at import, before the summary is
nightshift://plan-record/19f05497b379076e       the trailer rule, four parts
nightshift://plan-record/cebb14700c412289       scope is the reason and the `align ask` quote, t
nightshift://plan-record/de9df095ed3a6d7c       non-goals
nightshift://plan-record/e325b6f8e90450a9       the owner wants verification profile `balanced`
nightshift://plan-record/83341b2f1fac25e7       two additions to rule 4, on the owner's yes
  ...and 1 more

Imported 11 decisions from nightshift
```

## Found

- **The verification profile did not take.** The owner set `balanced` before `/nightshift:start`,
  and `ns shift-policy defaults-get` printed it, but the shift policy resolved to verification level
  `none`. The morning receipt then lists the gates as "Disabled by owner", which the owner did not
  do. The shift noticed, recorded it in the snag log, and ran the gate block by hand once before
  clock-out. Worth a look in `ns_start_snapshot`.
- **Permissions.** Setup wrote no permission settings, so the owner stayed at the terminal to approve
  commands. Fine for an attended first shift; an overnight one needs them configured first.

This shows a bounded claim: on a real repository, a short attended shift turned a loosely worded
request into two reviewed commits, and left decisions another tool could read back. It does not show
an unattended or overnight run.
