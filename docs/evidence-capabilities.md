# Evidence and receipts

The evidence surface is what a reviewer re-runs: what the shift measured, against which baseline,
and what changed by morning. The agent writes the receipts; Nightshift ships the templates it
writes them from, an append-only ledger to record findings in, and the renderer that turns those
records into the morning receipt. Everything stays on your machine: there is no telemetry.

## Reviewing a shift

Open the [morning receipt](morning-receipt.md#the-morning-receipt) first to see how the shift ended and what needs
attention. Then use the receipts to find the actual changes and their verification.

| Record | What to look for |
| --- | --- |
| `.nightshift/receipts/` | Each item's result or current progress, the index, the morning receipt, checks run, limitations, and output locations. |
| Local commits or output files | The change itself, including anything a receipt did not mention. |
| `.nightshift/inbox/parking-lot.md` | Decisions to accept or reverse, with the default and rollback. |
| `.nightshift/inbox/snag-log.md` | Unresolved findings and the reasons others were fixed or rejected. |

The [example receipts](../examples/receipts.md#receipts) includes a completed item, an unfinished
item, and a correction to an earlier result. Read the verification and limitations together:
passing a focused test does not mean an unrun integration suite passed. Usage comes from host
records when available; an unavailable dimension is never zero or an estimated price.
The [receipts guide](receipts.md#receipts-and-token-usage) explains token accounting, duration, and progress cadence.

Receipts can be disabled by owner policy. That does not remove the work contract or other records,
and it does not make an unchecked output verified. The receipts and handoff settings are in
[Owner knobs](knobs.md#shift-handoff-and-archive).

### Artifact receipts and archive

In a persistent folder without Git, the item's receipt file records completion.
Source and checkpoint receipts remain separate records under the same folder.

Doctor names the newest receipt. When the receipts path is not a usable folder, Doctor offers to
replace it, and Start, Hunt, Quality and Schedule refuse to begin until it is fixed. Archive files a
ticked item's receipt with the shift and keeps an open item's receipt live.
Other finished records can be moved out of the live working files during Archive; open work and
unanswered decisions stay live. Removing old archived history is a separate retention choice.
See [Archive and continue](archive.md#archive-and-continue), the [Archive contract](../plugins/nightshift/skills/archive/SKILL.md), and
[command reference](commands.md#command-reference) for the file operations.

## What ships

| Helper | What it does |
| --- | --- |
| `ns evidence` | Append-only findings ledger at `.nightshift/run/evidence/findings.jsonl` |
| `ns evidence-compare` | Classifies each finding against its baseline — new, cleared, unchanged, regressed, unavailable |
| `ns evidence-archive` | Files the ledger with the shift; the clock-out gate calls it |
| `ns morning-receipt` | Renders the morning receipt from the ledger, the resolved policy, and the working files |
| item receipt | Artifact-mode completion receipts under `.nightshift/receipts/` |
| `ns check-report` | Checks a cited report against its source manifest |
| `ns continuity-handoff` | Cross-host handoff packages and the on-disk takeover fence |

Every one has a native Windows twin under `runtime/windows/`. The plugin ships no Python. The
bash helpers use `jq` for the JSON they read and write, and fall back to an inline `python3`
program when `jq` is absent; with neither, they say what is missing and stop rather than write a
half-record. Hooks never depend on either — see
[the parser rules](how-it-works.md#three-policy-layers-and-one-resolved-view).

## What the model writes

[`receipts/cycle-specialist-evidence.md`](../plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md#cycle--specialist--evidence)
carries a block per receipt shape: cycle, coverage, defect, source policy, history, specialist. The
model copies the matching block and fills every field. A field the tools did not produce is
`unavailable` — never "no findings", never passed. Untrusted fetched text is instructional
material, not owner intent, and the model is the boundary that decides.

Two receipts have a fixed trigger:

- a **baseline**, once per source class, before the first fix that answers that source;
- a **checkpoint**, before a risky cluster — a migration, a codemod, a tooling change, anything
  whose undo is not obvious.

Cited reports, SEO audits, sourced documentation, and research synthesis follow
[`cited-research.md`](../plugins/nightshift/skills/nightshift/references/shift/cited-research.md#cited-research-and-report). Source
policies (`closed-list`, `bounded-discovery`, `connected-corpus`) decide what may be fetched.

## Evidence lines

[Evidence](evidence.md#evidence) covers asking for evidence, the evidence catalog, and what a
missing file does to the tick. Each shipped catalog entry is one file under
`skills/nightshift/references/evidence/kinds/`; owner entries live in the project's
`.nightshift/catalogs/evidence/`, the user folder (`$XDG_CONFIG_HOME/nightshift/catalogs/evidence`
on POSIX, `%APPDATA%\nightshift\catalogs\evidence` on Windows), or a folder named by
`catalogs.evidence.paths`, and never leave the machine. `ns catalog-index --catalog evidence`
lists every source, and an entry is read in full only when a drafted item fits it. When evidence
cannot be produced, the agent records it with `ns evidence-unavailable`.

## Policy behind a receipt

Three layers resolve before the site arms — permanent rules, remembered defaults, and tonight's
snapshot. The receipt names the resolved verification level, the tooling policy, the completion
mode, and every elevation allowance with its provenance. The layers themselves are described in
[How Nightshift works](how-it-works.md#three-policy-layers-and-one-resolved-view) and every
individual key in [Owner knobs](knobs.md#owner-knobs).

Verification profiles (`fast`, `balanced`, `strict`, `custom`) live in
[`references/profiles/`](../plugins/nightshift/skills/nightshift/references/profiles/) alongside the
`no-push`, `isolated-branch`, and `strict-secrets` rule profiles. A zero-gate `fast` shift is
first-class: items and receipts land with no automated checks, and the receipt says so in the
`Verified:` line rather than leaving it blank.

## Missing tooling

The tooling policy decides what a shift may add: `existing-tools` scans with what is installed,
`review-missing` holds the clock until the owner approves a plan, `auto-add` may install under the
elevation categories the shift already allows. Artifact mode is always `existing-tools`.

[`tooling-hints.md`](../plugins/nightshift/skills/nightshift/references/compose/tooling-hints.md#tooling-hints) names the
tools commonly used for a capability, by ecosystem. It is a starting point, not authority: what the
project already configures wins, and a capability that cannot be satisfied is reported
`unavailable` rather than skipped quietly. When something is added, `ns provision` captures
the write surface first so the change can be undone — the seatbelt described in
[`provisioning-engine.md`](../plugins/nightshift/skills/nightshift/references/compose/provisioning-engine.md#auto-add-seatbelt-frozen).

## Optional read-only helpers

Two helpers exist for hosts that have them and are ignored where they do not. Both read only, write
nothing, install nothing, and ask nothing — no skill, gate, or catalog entry requires either one.

`ns normalize-output` (native Windows: `ns.ps1 normalize-output`) turns one
tool's raw output into one compact summary: a headline, a bounded table of the worst rows, the
digest of the result, and the input path with its own sha256. It reads `eslint-json`, `tsc`,
`coverage-summary`, `sarif`, `npm-audit`, `junit` and `lcov`, with `pytest-junit` as an alias of
`junit`. The summary is deterministic, so the model reads it instead of a large file and two nights
diff byte for byte; `--json` prints the same thing as one canonical object for `ns evidence append`
to carry as a finding of domain `tool-output`. The result digest covers the headline and the counts,
so a rerun that finds the same thing carries the same digest, and a metric with no denominator reads
`unmeasured` rather than a percentage.

`ns inventory` (native Windows: `ns.ps1 inventory`) reports what the work
target declares. It walks the tree — `git ls-files` in a repository, so .gitignore is honoured —
and prints one table per workspace package: the package manager and lockfile behind it, the
scripts declared for test, lint, typecheck, build and format, the config files present, and each
named tool as `declared`, `runnable` or `absent`. Monorepos fall out of that walk. Those three
words are the whole verdict — the report never says a project is set up wrongly, and it caches
nothing, so a second run reads the tree again. Doctor may offer it; Status prints it only when
asked; Hunt and Quality name it as optional, and Automatic composes a shift without it.

When a helper cannot read what it was handed — an unsupported shape, a missing file, or no `jq` for
a JSON format — it prints one line, `unavailable <what>: <reason>`, and exits 3. That is a
first-class answer: a tool that did not report is never recorded as a tool that found nothing.

## Modes

**Repository mode** leaves local conventional commits as the punch-list contract specifies:
usually one per item, or a coherent batch when requested. A contract can also request uncommitted
changes. The receipt must state what was actually recorded.

**Artifact mode** records an item's completion in its file under `.nightshift/receipts/`.
Review the output files themselves in either case. No work-target Git repository is
required, and no Git terminology appears in artifact-mode receipts.

## Cross-host continuity

The punch list, parking lot, snag log, and receipts hold authority — not either conversation.
`ns continuity-handoff` builds a versioned handoff package and reads the same on-disk fence
Start reads, so two workers are never admitted. Multi-night campaigns are independent bounded
shifts: the next night begins only after the previous one archives or the owner accepts its
handoff.

## Optional SonarQube inspection

A local SonarQube Community Edition instance can back the site inspection when the project has a
`sonar-project.properties` file and the instance answers. It is never a per-item check; see
[`gates-catalog.md`](../plugins/nightshift/skills/nightshift/references/compose/gates-catalog.md#gates-catalog).

---

[Read real runs](../examples/README.md#real-runs) · [Documentation index](README.md#documentation)
