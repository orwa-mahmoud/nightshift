CAT="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/compose/gates-catalog.md"

@test "proposes the TypeScript toolchain for a package.json + tsconfig.json project" {
  grep -q 'package.json' "$CAT"
  grep -q 'tsconfig.json' "$CAT"
  grep -qE 'eslint.*tsc.*(test|noEmit)' "$CAT"
}

@test "proposes the Python toolchain for a pyproject/requirements project" {
  grep -qE 'pyproject.toml|requirements.txt' "$CAT"
  grep -qE 'ruff.*mypy.*pytest' "$CAT"
}

@test "covers Go, Rust, Helm, and a Makefile fallback" {
  grep -q 'go.mod' "$CAT"
  grep -q 'Cargo.toml' "$CAT"
  grep -qiE 'chart.yaml|kustomize' "$CAT"
  grep -q 'Makefile' "$CAT"
}

@test "proposes bats, shellcheck, and plugin validate for a Claude or Codex plugin" {
  grep -qE '\.claude-plugin/|\.codex-plugin/' "$CAT"
  grep -qF 'plugins/<name>/' "$CAT"
  grep -q 'bats -r tests/' "$CAT"
  grep -q 'shellcheck' "$CAT"
  grep -q 'claude plugin validate . --strict' "$CAT"
}

@test "plugin detection sits after language stacks and before the Makefile fallback" {
  awk '
    /^\| `package.json`/ { ts=NR }
    /^\| `\.claude-plugin/ { plugin=NR }
    /^\| `Makefile`/ { make=NR }
    END {
      if (!(ts && plugin && make)) { print "missing row"; exit 1 }
      if (!(ts < plugin && plugin < make)) { print "order"; exit 1 }
    }
  ' "$CAT"
}

@test "Setup treats a nested plugins/<name> manifest as a plugin-stack match" {
  SETUP="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/setup/SKILL.md"
  QUALITY="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/quality/SKILL.md"
  grep -qF 'plugins/<name>/.claude-plugin/' "$SETUP"
  grep -qF 'plugins/<name>/.codex-plugin/' "$SETUP"
  grep -qF 'plugins/<name>/' "$QUALITY"
}

@test "states that detection only proposes and the user decides" {
  grep -qiE 'propose|user decides|opt-in' "$CAT"
}

@test "the item gate runs before a commit or artifact receipt" {
  grep -qF 'right before its commit or artifact receipt' "$CAT"
}

@test "is Sonar-ready and keeps coverage a tripwire" {
  grep -qi 'sonar' "$CAT"
  grep -qi 'tripwire' "$CAT"
}
