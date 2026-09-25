# Receipts

Illustrative. A real shift writes `.nightshift/receipts/README.md` and one `<NN>-<slug>-<id>.md`
per item.

## Index

```markdown
# Receipts — 2026-09-09

| Item | State | **Usage** | **Time** | Receipt |
| --- | --- | --- | --- | --- |
| 1. Fix the resolver's relative-import failures | ticked | **input 128.4k · cache_write 12.1k · cache_read 96.0k · output 9.3k · reasoning 2.1k** | **41m 12s working** | [./01-fix-the-resolver-s-relative-import-failures-k7q2.md](./01-fix-the-resolver-s-relative-import-failures-k7q2.md) |
| 2. Cover the parser's error paths | open | **input 64.2k · cache_write 8.0k · cache_read 40.0k · output 9.4k · reasoning 1.0k** | **18m 3s working · 12m paused** | [./02-cover-the-parser-s-error-paths-m3xd.md](./02-cover-the-parser-s-error-paths-m3xd.md) |
| **Totals** | | **input 192.6k · cache_write 20.1k · cache_read 136.0k · output 18.7k · reasoning 3.1k** | **59m 15s working · 12m paused** | |
```

## One item receipt

```markdown
# 1. Fix the resolver's relative-import failures.

| Tokens | Amount |
| --- | ---: |
| input | 128.4k |
| cache write | 12.1k |
| cache read | 96.0k |
| output | 9.3k |
| reasoning | 2.1k |

<!-- tokens 128400 12100 96000 9310 2140 -->
claude claude-opus-5 · 1 segment. Cache reads and cache writes are separate from the input figure; reasoning is inside output.

| Time | |
| --- | --- |
| working | 41m 12s |
| wall | 41m 12s |
| span | 2026-09-09T02:00Z → 2026-09-09T02:41Z |

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
```
