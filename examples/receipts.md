# Receipts

Illustrative. A real shift writes `.nightshift/receipts/README.md` and one `NN-slug.md` per item.

## Index

```markdown
# Receipts — 2026-09-09

| Item | State | **Tokens** | **Time** | Receipt |
| --- | --- | --- | --- | --- |
| 1. Fix the resolver's relative-import failures | ticked | **137.7k** | **41m 12s** | [./1-fix-the-resolvers-relative-import-failures.md](./1-fix-the-resolvers-relative-import-failures.md) |
| 2. Cover the parser's error paths | open | **73.6k** | **18m 03s** | [./2-cover-the-parsers-error-paths.md](./2-cover-the-parsers-error-paths.md) |
| **Totals** | | **211.3k** | **59m 15s** | |
```

## One item receipt

```markdown
# 1. Fix the resolver's relative-import failures.

## What was delivered

`import` statements that walk up out of the package root resolve the same way in the test runner
as they do in the build.

## Why

The resolver normalised the path before checking containment, so `../../lib` and `lib` compared
equal once both collapsed.

## Tried and rejected

Normalising first, then checking the collapsed path. That is the comparison that failed in CI.

## Verification

`npm test -- resolver` — 41 passed, 0 failed. `npm run build` — clean.

## Outputs

`fix(resolver): check containment before normalising`

## Parked decisions and snags

None.

**Usage:** input 128.4k · cache_write 12.1k · cache_read 96.0k · output 9.3k · reasoning 2.1k
  Source: claude claude-opus-5, cumulative counters, segments 1; exact: 128400 / 12100 / 96000 / 9310 / 2140
  Cache reads and cache writes are separate from the input figure; reasoning is inside output.
**Duration:** 41m 12s
```
