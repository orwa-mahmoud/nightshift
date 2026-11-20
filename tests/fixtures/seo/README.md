# SEO evidence fixtures (Wave 1)

Read-only fixtures for the three SEO evidence modes defined in `seo-audit.md`.
Schemas live under
`plugins/nightshift/config/schemas/v1/`. Runtime helpers
(`seo-evidence.sh`) are **planned for Wave 2** — these files validate contracts
only.

## Layout

| Path | Mode | Scenario |
|------|------|----------|
| `local/static-site-inventory.json` | **Local** | Static docs tree with template clusters, orphan candidate, intent map, cannibalization, content gap, and explicit `notMeasured` rows for every surface Local cannot observe. |
| `live/bounded-crawl-snapshot.json` | **Live** | Bounded crawl on `https://docs.example.test` only: redirect/canonical/robots captures, sitemap gap, schema error, source-vs-rendered diff, blocked `/admin`, off-origin skip, malicious page-instruction trap, and crawl failures. |
| `connected/connected-export-sample.json` | **Connected** | Normalized Search Console + analytics export semantics with period comparison, segmentation highlights, and the clicks-not-sessions disclaimer. |
| `connected/search-console-export.csv` | **Connected** | Raw owner-supplied Search Console CSV sample referenced by the normalized fixture. |
| `connected/analytics-export.csv` | **Connected** | Raw owner-supplied analytics CSV sample referenced by the normalized fixture. |

The legacy cited-research bundle remains at `tests/fixtures/seo-audit/` for
`check-report` verification.

## Local mode (`local/static-site-inventory.json`)

- **Inventory:** six pages across landing, doc, blog, and legacy templates.
- **Template clusters:** doc-page, landing, blog-post with duplicate-risk signals.
- **Orphan:** `/legacy/old-api` has zero inbound internal links.
- **Intent map:** install (served), SEO audit (cannibalized across two pages),
  release history (served), legacy migration (gap).
- **Not measured:** live crawl, production rendering, backlinks, Search Console,
  analytics, field/lab performance, rankings — each with an honest reason.

## Live mode (`live/bounded-crawl-snapshot.json`)

- **Approved origins:** `https://docs.example.test` only; off-origin URLs are
  recorded as skipped, never fetched.
- **Budget:** 25 URLs, depth 3, 12 pages, 120 seconds — partially exercised.
- **Sitemap health:** declared vs crawled mismatch plus sitemap-only URL.
- **Redirect/canonical:** trailing-slash 301 on install; canonical mismatch on
  seo-audit guide.
- **Robots:** `/admin` blocked by robots.txt and returns 401.
- **Malicious instructions:** `/trap/agent-instructions` embeds prompt-injection
  samples that must be recorded, never executed or treated as owner intent.
- **Schema:** invalid FAQPage on seo-audit page.

## Connected mode (`connected/`)

- **Search Console rows:** query/page/device/country/search-appearance segments
  showing cannibalization signal for “seo audit checklist”.
- **Analytics rows:** sessions/users/engagement by page — intentionally different
  totals from Search Console clicks.
- **Period comparison:** August vs July deltas for clicks, impressions, sessions,
  engagement rate.
- **Disclaimer:** `metricsDisclaimer.clicksNotSessions` is always true; clicks
  must never be reported as sessions.

## Validation

```bash
bats tests/seo-fixtures.bats
```

Each primary JSON fixture must validate against its schema via
`tests/helpers/validate-json-schema.py`.
