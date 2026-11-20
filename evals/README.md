# Contract schema and size budgets

Repository-owned **contract schema and size-budget checks** for Nightshift catalog
entries and composer skills. The public command surface stays the existing
Setup / Hunt / Quality / Start skills; this directory is the maintainer SDK.

```text
evals/validate.sh [--report] [path]   schema + instruction-size checks
evals/run.sh                          same checks, writes a human-review report
```

`validate.sh` prints the configured byte/token budget and the measured size for
every contract it inspects. A malformed contract fails with a precise reason
(`missing ending`, `broken reference: …`, `oversized instructions: …`).

`evals/cases/v1.json` is a versioned scenario book. The SDK checks each case
against the case schema, frozen identifiers, and fixture markers. That is not a
host-agent run. Comparing a contract-enabled session with a normal host-agent
baseline is informational: the report records `not-run` unless someone later
attaches samples, and that comparison is never a release gate.

## Layout

| Path | Role |
| --- | --- |
| `schema/` | Case, contract, and report schemas |
| `cases/v1.json` | Versioned scenario book |
| `fixtures/` | Representative repository and artifact trees |
| `reports/` | Generated `latest.md` / `latest.json` (gitignored) |
| `lib/sdk.py` | Schema and size-budget SDK |
| `../plugins/nightshift/config/schemas/v1/identifiers.json` | Frozen host, work-mode, evidence, and capability identifiers |

## Reading a report

Open `evals/reports/latest.md` after `evals/run.sh`. Failures list the contract
or case id and the reason. Size rows are the oversized-instruction check. The
informational baseline section is not a gate.

## Adding a case

Append an object to `cases/v1.json` that matches `schema/case-v1.json`. Point
`fixture` at a directory under `fixtures/` that has `.eval-markers.json`.
Priority contracts (Hunt, Quality, SEO, Coverage, Defect, Research synthesis,
Documentation writing) each need at least one `positive` and one `negative`
schema row.
