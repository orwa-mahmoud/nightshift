# Drafting Table

---

## Plan: Settings page

- [ ] **1. No evidence line.**
  - Verify: `bats tests/settings.bats`
  - Commit: `feat: add the settings page`

- [ ] **2. Evidence on one line.**
  - Verify: `bats tests/settings.bats`
  - Evidence: before/after screenshots at 375 and 1280 px, light and dark
  - Commit: `feat: restyle the settings page`

- [ ] **3. Evidence as a list.**
  - Verify: `bats tests/settings.bats`
  - Evidence:
    - the command, the machine, and the before/after timings
    - the tests added and the behaviour each covers
  - Commit: `perf: cache the settings query`

- [ ] **4. Evidence that names nothing.**
  - Verify: `bats tests/settings.bats`
  - Evidence:
  - Commit: `feat: add the settings export`

- [ ] **5. Evidence that names nothing, last.**
  - Verify: `bats tests/settings.bats`
  - Commit: `feat: add the settings import`
  - Evidence:
