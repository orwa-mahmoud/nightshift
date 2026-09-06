# Evidence and receipts

A tick is a claim. The evidence surface is what turns that claim into something a reviewer can
re-run: what the shift measured, against which baseline, and what changed by morning.

The model writes the receipts. Nightshift ships the templates it writes them from, an append-only
ledger it can record them in, and a renderer that turns those records into one morning page.
Nothing here scans a project or judges a finding on the model's behalf.

## What ships

| Helper | What it does |
| --- | --- |
| `ns evidence` | Append-only findings ledger at `.nightshift/evidence/findings.jsonl` |
| `ns evidence-compare` | Classifies each finding against its baseline — new, cleared, unchanged, regressed, unavailable |
| `ns evidence-archive` | Files the ledger with the shift; the clock-out gate calls it |
| `ns morning-receipt` | Renders the morning receipt from the ledger, the resolved policy, and the working files |
| `ns write-receipt` | Artifact-mode completion receipts under `.nightshift/receipts/` |
| `ns check-report` | Checks a cited report against its source manifest |
| `ns continuity-handoff` | Cross-host handoff packages and the on-disk takeover fence |

Every one has a native Windows twin under `runtime/windows/`. The plugin ships no Python. The
bash helpers use `jq` for the JSON they read and write, and fall back to an inline `python3`
program when `jq` is absent; with neither, they say what is missing and stop rather than write a
half-record. Hooks never depend on either — see
[the parser rules](how-it-works.md#three-policy-layers-and-one-resolved-view).

## What the model writes

[`receipts/cycle-specialist-evidence.md`](../plugins/nightshift/skills/nightshift/references/receipts/cycle-specialist-evidence.md)
carries a block per receipt shape: cycle, coverage, defect, source policy, history, specialist. The
model copies the matching block and fills every field. A field the tools did not produce is
`unavailable` — never "no findings", never passed. Untrusted fetched text is instructional
material, not owner intent, and the model is the boundary that decides.

Two receipts have a fixed trigger:

- a **baseline**, once per source class, before the first fix that answers that source;
- a **checkpoint**, before a risky cluster — a migration, a codemod, a tooling change, anything
  whose undo is not obvious.

Cited reports, SEO audits, sourced documentation, and research synthesis follow
[`cited-research.md`](../plugins/nightshift/skills/nightshift/references/shift/cited-research.md). Source
policies (`closed-list`, `bounded-discovery`, `connected-corpus`) decide what may be fetched.

## Policy behind a receipt

Three layers resolve before the site arms — permanent rules, remembered defaults, and tonight's
snapshot. The receipt names the resolved verification level, the tooling policy, the completion
mode, and every elevation allowance with its provenance. The layers themselves are described in
[How Nightshift works](how-it-works.md#three-policy-layers-and-one-resolved-view) and every
individual key in [Owner knobs](knobs.md).

Verification profiles (`fast`, `balanced`, `strict`, `custom`) live in
[`references/profiles/`](../plugins/nightshift/skills/nightshift/references/profiles/) alongside the
`no-push`, `isolated-branch`, and `strict-secrets` rule profiles. A zero-gate `fast` shift is
first-class: items and receipts land with no automated checks, and the receipt says so in the
`Verified:` line rather than leaving it blank.

## Missing tooling

The tooling policy decides what a shift may add: `existing-tools` scans with what is installed,
`review-missing` holds the clock until the owner approves a plan, `auto-add` may install under the
elevation categories the shift already allows. Artifact mode is always `existing-tools`.

[`tooling-hints.md`](../plugins/nightshift/skills/nightshift/references/compose/tooling-hints.md) names the
tools commonly used for a capability, by ecosystem. It is a starting point, not authority: what the
project already configures wins, and a capability that cannot be satisfied is reported
`unavailable` rather than skipped quietly. When something is added, `ns provision` captures
the write surface first so the change can be undone — the seatbelt described in
[`provisioning-engine.md`](../plugins/nightshift/skills/nightshift/references/compose/provisioning-engine.md).

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

**Repository mode** ends each work package in one conventional commit; the morning handoff is the
punch list, the parking lot, the snag log, and `git log` on the work target.

**Artifact mode** completes through `ns write-receipt` into `.nightshift/receipts/`,
recording item text, verification commands, optional decisions, and hashed outputs. Status and
Doctor surface receipt counts; Archive files them with the shift. No git terminology appears in an
artifact-mode receipt because no repository is behind it.

## Cross-host continuity

The punch list, parking lot, snag log, and receipts hold authority — not either conversation.
`ns continuity-handoff` builds a versioned handoff package and reads the same on-disk fence
Start reads, so two workers are never admitted. Multi-night campaigns are independent bounded
shifts: the next night begins only after the previous one archives or the owner accepts its
handoff.

## Contract schema and size budgets

`evals/` holds the catalog contract schema, a versioned case book, frozen identifiers, and
instruction-size budgets. `evals/run.sh`, `evals/validate.sh`, and `tests/evals.bats` check schema
and size. They do not run a host-agent matrix; a catalog contribution is still read by a person.

## Limits

- Ticks are self-reported. A receipt records honestly; it does not certify independent proof.
- A comparison is only as good as its baseline. A tool that failed mid-shift is reported
  `unavailable`, never folded into the cleared count.
- Connectors beyond local files and owner-supplied exports are not part of this package.
- No telemetry. Product measures live in local receipts only.
- Optional **SonarQube Community Edition** can back a site inspection when
  `sonar-project.properties` exists and a local instance answers; Sonar is never a per-item gate.
  See [`gates-catalog.md`](../plugins/nightshift/skills/nightshift/references/compose/gates-catalog.md).
