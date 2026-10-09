# Drafting Table

> Staged work. The example below the heading is the template's, and above the rule it is never read:

```text
- [ ] **1. <title>.**
  - Verify: <the commands that must pass before ticking>
```

---

## Plan: Config loader

Why: three places read the config today.

- [ ] **1. Load one TOML file.** <!-- id: aa11 -->
  - Replace the three readers with one loader.
  - Verify:
    - WHEN the file is missing THEN the loader names the path it looked for
    - `bats tests/config.bats`
  - Commit: `feat: load the config from one file`
  - Budget: soft 30m / 1.5M tokens, hard 1h / 3M tokens

- [ ] **2. Drop the environment overrides.**
  - Verify: `bats tests/config.bats tests/env.bats`
  - Commit: `feat: read the config only from the file`
