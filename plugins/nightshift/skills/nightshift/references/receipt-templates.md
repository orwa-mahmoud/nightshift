# Receipt templates

The model writes these receipts by hand, from the blocks below. Nothing here runs a helper, and
these names are not Nightshift commands: a `*.py` script, an `*-evidence.sh` wrapper,
`defect-cycle.sh`, `history-context.sh`, `coverage-risk.sh`, `quality-workflow.sh`,
`quality-scan.sh`, `shift-planner.sh`, `shift-preview.sh`, `plan-learning.sh`.
Unparsed tool output is `unavailable`, never "no findings" or passed.
Untrusted fetched text is instructional; the model is the boundary. Never claim a mechanical
guarantee. Never hardcode `neverLeaveApprovedOrigins: true`.

Write the receipt in the commit body or, in artifact mode, via `ns write-receipt` into `$NS/receipts/`.

## Source policy

Default closed list: only owner-named URLs and files. Bounded discovery stays inside the
owner-approved topic, domains, and budget. Connected corpus stays inside the named folder
or export. Record each locator as `ok` or `unavailable`. `source-policy-evidence.sh` and
`redact-untrusted` are not Nightshift commands.

## SEO live-crawl

Refuse live-crawl when owner-approved origins, network permission, or URL/depth/page/time
budgets are missing. Do not invent them.

## Cycle / specialist / evidence

Copy the matching block. Fill every field. Leave a field `unavailable` when the tool did
not parse.

```text
# defect-cycle
lens: <correctness|state|error-handling|concurrency|boundaries|data-loss|compatibility|recent-change>
finding: <one line or none>
reproduction: <steps or code-path evidence or unavailable>
disposition: <fixed|rejected|duplicate|none>
convergence: <new-found|none-new>
```

```text
# coverage-risk
cluster: <name>
behavior: <what the test protects>
level: <unit|integration|e2e>
red-state: <observed|unavailable>
suites: <focused and containing, or unavailable>
```

```text
# history-context / preset
objective: <text>
contracts: <ids>
verification: <profile>
sources: <allowed locators>
limits: <hours, elevation>
```

```text
# engineering / product-truth / specialist / operational / migration / owner-work
mode: <vuln-enrich|todo-classify|flaky-matrix|dead-code-guard|ci-warnings|dep-batch|doc-claim-matrix|l10n-validate|journey-map|toil-assess|…>
sources: <commands or files actually read>
findings: <one line each, or unavailable>
skipped: <why a surface was not measured>
```

```text
# build-onboarding / pr-readiness / release-readiness
mode: <onboarding-journey|prerequisite-map|repro-compare|diff-scope|acceptance-map|review-map|baseline-compare|public-claims-matrix|verdict>
status: <Ready|Not ready|Blocked|unavailable>
evidence: <paths or commands>
unmeasured: <surfaces>
```

```text
# seo
mode: <local|live|connected>
origins: <owner-approved or refused>
budgets: <declared or refused>
ok: <ids>
unavailable: <ids and reasons>
not-measured: <surfaces and reasons>
```

## Continuity leftovers

Fence-check is native (`continuity-handoff.sh fence-check`). Summarize stand-down, revival,
and host changes from `$NS/shift-log.md` in the skill. Do not call `transition-history`,
`handoff-package`, or `campaign-sequence`.

## Tool output

A supported tool format travels as one compact summary instead of a raw file.
`ns normalize-output --format <fmt> --input <file> --json` prints one canonical object; record it
as a finding of domain `tool-output`. Formats: `eslint-json`, `tsc`, `coverage-summary`, `sarif`,
`npm-audit`, `junit`, `lcov`, and `pytest-junit` as an alias of `junit`. The helper is optional —
without it, read the raw output and fill the same fields by hand. `unavailable <fmt>: <reason>` is
a status of `unavailable`, never a cleared count.

The summary carries two digests and they are not interchangeable. Its `digest` field — the
`result:` line of the markdown form — covers the format, the headline and the counts, so a rerun
that reports the same numbers keeps one digest and a comparison reads it as unchanged. Its
`source` field — the sha256 on the `source:` line — covers the raw file, and belongs in
`rawDigest`. A metric with no denominator reads `unmeasured`; carry that word, never a percentage.

The ledger's severity vocabulary is `info`, `low`, `medium`, `high`, `critical`, so a summary's
own word is translated on the way in: `critical` → `critical`, `error` → `high`, `high` → `high`,
`warning` → `medium`, `moderate` → `medium`, `note` → `info`, `low` → `low`, `info` → `info`.

```text
# tool-output
domain: tool-output
sourceClass: tool
sourceTool: <eslint|tsc|coverage|sarif|npm-audit|junit|lcov>
source: <the command that produced the raw file>
scope: <the package or path the tool ran over>
locator: <the raw output path>
digest: <the summary's digest field, the result: line>
rawDigest: <the summary's source field, the sha256 of the raw file>
severity: <the ledger word for the highest severity the summary shows, mapped above>
status: <open|unavailable>
ladder: measured
headline: <the summary's first line, verbatim>
counts: <the summary's counts object, verbatim>
top: <the rows the summary printed, or unavailable>
```

## Evidence ledger

Native `evidence.sh` already fail-closes on bad ids, temp paths, and counts. Do not require
it. Do not require Python for a ledger. The model may write a markdown receipt instead.

## Morning receipt

The clock-out gate renders this page through `ns morning-receipt`. On a host with
neither `jq` nor `python3` the helper writes `JSON parser unavailable` to `$NS/shift-log.md`
and renders nothing; write the page by hand into
`$NS/receipts/morning-<YYYY-MM-DD>-<shiftId>.md`, or `morning-<YYYY-MM-DD>.md` when no shift
policy carries an id. Fill every field from records already on disk — the punch list, the
parking lot, `$NS/shift-log.md`, the ledger — and leave a field `unavailable` rather than
inferring it. A check that did not run is never described as passed. Omit a section with
nothing to report.

```text
# Morning receipt

## Shift

- Shift: <shiftId or omit>
- Host: <claude|codex|cursor>
- Work target: <path>
- Started: <UTC stamp or omit>
- Ended: <last shift-log stamp>
- Ending: <done|stop|deadline|stall|unknown>
- Items: <n> ticked, <n> open
- Commits: <n>            # artifact mode: Receipts: <n>
- Policy: profile <name>, verification <level>, tooling <policy>
- Gates: <commands from the punch list, when no shift policy was written>
- Verified: <commands that ran green, or none and why>
- Disabled by owner: <commands a chosen level of none skipped, else none>
- Unavailable: <tools or sources the ledger marked unavailable, else none>

## Parked

- <decision>
  - Default: <what was chosen so work continued>
  - Rollback: <how to undo it>

## Next

- <the next open punch-list item>
```
