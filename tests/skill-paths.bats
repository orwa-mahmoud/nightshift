SKILLS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills"
REFS="$SKILLS/nightshift/references"
HOSTS="$REFS/start-hosts.md"
PREFLIGHT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
PREFLIGHT_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/start-preflight.ps1"
SETUP="$SKILLS/setup/SKILL.md"
START="$SKILLS/start/SKILL.md"
STOP="$SKILLS/stop/SKILL.md"
HUNT="$SKILLS/hunt/SKILL.md"
QUALITY="$SKILLS/quality/SKILL.md"
SCHEDULE="$SKILLS/schedule/SKILL.md"
DOCTOR_SH="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"

# Shared skills are loaded unchanged by both hosts. Pin the path carriers and reject the unsafe
# host-only fallbacks; wording and line wrapping remain free to change.
@test "every skill reaches the runtime through the dispatcher, and derives nothing itself" {
  for s in "$SKILLS"/*/SKILL.md; do
    grep -qF '$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns' "$s" \
      || { echo "does not name the dispatcher: $s"; return 1; }
    grep -qF 'ns bind' "$s" || { echo "does not name the five bound facts: $s"; return 1; }
    # The resolving is the runtime's. A skill that still spells out a host's own answer will
    # drift from it, and the unsafe fallbacks are exactly how that used to go wrong.
    for bad in 'pwd -P' '${CLAUDE_PROJECT_DIR:-$PWD}' '${CODEX_PROJECT_DIR:-$PWD}' \
      '--project "$CLAUDE_PROJECT_DIR"'; do
      ! grep -qF -- "$bad" "$s" || { echo "re-derives the task root ($bad): $s"; return 1; }
    done
  done
}

# The permission mode is what a headless revival inherits. A copy written into a nested code repo
# grants the project nothing, and the shift discovers it at the first prompt of the night.
@test "setup writes the permission settings to an absolute path" {
  grep -qF '$TASK_ROOT/.claude/settings.local.json' "$SETUP"
}

@test "every skill takes the Nightshift directory from the dispatcher, not from a host rule" {
  for s in "$SKILLS"/*/SKILL.md; do
    grep -qF '`NS`' "$s" || { echo "does not name NS among the bound facts: $s"; return 1; }
    for bad in 'NS="$NIGHTSHIFT_WORKSPACE/.nightshift"' \
      "Join-Path \$NIGHTSHIFT_WORKSPACE '.nightshift'"; do
      ! grep -qF -- "$bad" "$s" || { echo "still binds NS by hand: $s"; return 1; }
    done
  done
}

@test "setup writes the rules file to the bound Nightshift directory" {
  grep -qF '$NS/rules.json' "$SETUP"
}

@test "setup writes state-version on a new workspace and migrates only on confirmation" {
  grep -qF '$NS/state-version' "$SETUP"
  grep -qF 'ns" migrate-state' "$SETUP"
  grep -qF 'only after an explicit yes' "$SETUP"
}

@test "setup scaffolds every template into the bound Nightshift directory" {
  for f in punch-list drafting-table parking-lot snag-log product-research opportunity-map; do
    grep -qF "\$NS/$f.md" "$SETUP" \
      || { echo "scaffold target not bound: $f"; return 1; }
  done
}

@test "shared plugin paths resolve once through both host conventions" {
  for s in "$SKILLS"/*/SKILL.md; do
    ! grep -qF '${CLAUDE_PLUGIN_ROOT}/' "$s" \
      || { echo "Claude-only bundled path: $s"; return 1; }
    ! grep -qF '${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}' "$s" \
      || { echo "Claude-first plugin fallback: $s"; return 1; }
    ! grep -qF '${PLUGIN_ROOT:-' "$s" \
      || { echo "unresolved shell fallback in shared skill: $s"; return 1; }
  done

  for s in setup start hunt quality doctor import-issues schedule archive stop reset purge; do
    f="$SKILLS/$s/SKILL.md"
    grep -qF '$NIGHTSHIFT_PLUGIN_ROOT' "$f" || { echo "no neutral plugin root: $s"; return 1; }
    grep -qF '${CLAUDE_PLUGIN_ROOT}' "$f" || { echo "no Claude plugin source: $s"; return 1; }
    grep -qF '$PLUGIN_ROOT' "$f" || { echo "no Codex plugin source: $s"; return 1; }
    grep -qF "skills/$s/SKILL.md" "$f" || { echo "no attached skill path: $s"; return 1; }
  done
}

@test "every dispatcher call is qualified by the resolved plugin root" {
  for s in "$SKILLS"/*/SKILL.md "$REFS"/*.md "$REFS"/shifts/*.md; do
    # A bare `runtime/ns` in a command is a relative path, and the working directory persists
    # between calls on every host. Prose may name the file; a command may not.
    if grep -nE '^[^`]*[^/A-Z_]runtime/ns"' "$s" | grep -vF '$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns'; then
      echo "unqualified dispatcher call: $s"
      return 1
    fi
  done

  grep -qF 'ns" import-issues' "$SKILLS/hunt/SKILL.md"
  grep -qF 'ns" import-issues' "$REFS/shifts/github-issue-hunt.md"
}

@test "shared references are host-neutral and skill redirects name both hosts" {
  for ref in "$SKILLS/nightshift/references"/*.md "$SKILLS/nightshift/references/shifts"/*.md; do
    ! grep -qF '/nightshift:' "$ref" \
      || { echo "host-specific command in shared reference: $ref"; return 1; }
  done

  python3 - "$SKILLS" <<'PY'
import pathlib
import re
import sys

for path in pathlib.Path(sys.argv[1]).glob("*/SKILL.md"):
    for paragraph in re.split(r"\n\s*\n", path.read_text()):
        if "/nightshift:" in paragraph and not (
            "Claude Code" in paragraph and "Codex" in paragraph
        ):
            raise SystemExit(f"unpaired host invocation: {path}")
PY
}

# git resolves its repo from the working directory, so the receipts repo is the one place a stray
# cd would init a repo inside the code tree instead of the site.
@test "setup inits the receipts repo without relying on the working directory" {
  grep -qF 'git -C "$NS" init' "$SETUP"
  grep -qF '`.shift-lease`' "$SETUP"
  grep -qF '`.mutex-scope`' "$SETUP"
  grep -qF '`.lease-lock.d/`' "$SETUP"
}

@test "setup asks before writing Cursor CLI file hooks and defaults to skip" {
  grep -qF 'Cursor CLI file hooks — ask, default no' "$SETUP"
  grep -qF 'on anything but a clear yes, skip it' "$SETUP"
  grep -qF '.cursor/hooks.json' "$SETUP"
  grep -qF 'hooks/cursor/hooks.json' "$SETUP"
  grep -qF 'a Cursor limitation, not a Nightshift skip' "$SETUP"
  grep -qF 'Never create a second `.nightshift/`' "$SETUP"
}

@test "setup refuses disposable ChatGPT scratch before writing" {
  grep -qF '/workspace/scratch/' "$SETUP"
  grep -qF 'Before creating or changing any file' "$SETUP"
  grep -qF 'create no `$NS/` directory' "$SETUP"
  grep -qF 'Open your project in Codex' "$SETUP"
  grep -qF 'persistent local folder' "$SETUP"
  grep -qF 'Do not mention Claude Code' "$SETUP"
}

@test "scratch detection does not reject legitimate non-git projects" {
  grep -qF 'Do not infer “temporary” merely because the' "$SETUP"
  grep -qF 'project is not a git repository' "$SETUP"
  grep -qF 'A non-git project outside that explicit scratch path remains valid' "$SKILLS/nightshift/SKILL.md"
}

# Structural instruction contracts, not runtime E2E: pin the lifecycle words and shipped paths
# whose accidental removal would leave a scheduled or headless shift unarmed or unstoppable.
@test "start explicitly arms the shift and both host watchmen" {
  grep -qF '$NS/.shift-armed' "$START"
  grep -qF 'ns" watchman' "$START"
  grep -qF '### Bind this session' "$START"
  grep -qF '$NS/.shift-lease' "$START"
  grep -qF 'ns_lease_reset_stale' "$START"
  grep -qF ': nightshift-binding-probe' "$START"
  # Start no longer restates what the preflight does or does not need; the policy verdict says it.
  grep -qF 'Never install jq or python3' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'ns" start-preflight' "$START"
}

# The lease reader and the watchman recovery keys are the helper's job on both hosts. A skill that
# re-derived them would drift from the script that actually refuses to arm.
@test "the preflight helper reads the lease and the watchman recovery keys on both hosts" {
  grep -qF 'ns_lease_valid' "$PREFLIGHT"
  grep -qF 'Read-NSLease' "$PREFLIGHT_PS1"
  for key in watchRetrySeconds revivalPrompt freshRevivalPrompt; do
    grep -qF "$key" "$PREFLIGHT" || { echo "POSIX helper drops $key"; return 1; }
    grep -qF "$key" "$PREFLIGHT_PS1" || { echo "Windows helper drops $key"; return 1; }
  done
}

@test "start validates the captured Codex identity before its watchman or item work" {
  checkpoint="$(grep -n '^### Codex identity checkpoint' "$START" | cut -d: -f1)"
  watchman="$(grep -n '^## [0-9]\+\. Arm the night watchman' "$START" | cut -d: -f1)"
  work="$(grep -n '^## [0-9]\+\. Work' "$START" | cut -d: -f1)"
  [ -n "$checkpoint" ]
  [ "$checkpoint" -lt "$watchman" ]
  [ "$checkpoint" -lt "$work" ]
  grep -qF -- '--phase bind' "$START"
  grep -qF 'ns_codex_identity_kind' "$START"
  grep -qF 'Get-NSCodexIdentityKind' "$START"
  grep -qF ': nightshift-binding-probe' "$START"
  grep -qF 'Remove only the markers this start created' "$START"
  grep -qF '.shift-armed' "$START"
  grep -qF '.shift-session' "$START"
  grep -qF 'before the watchman or item work' "$START"
  grep -qF 'with no other command between marker removal' "$START"
}

# The order is the whole point: prove nothing is live, stand the old watchman down, only then
# remove markers. A watchman that survives into the clearing step can advance the lease it is
# about to lose. The order now lives in the helper, so the helper is where it is pinned.
@test "the preflight refuses an active watchman before clearing stale lease state" {
  active="$(grep -n 'a live watchman is recovering this shift' "$PREFLIGHT" | cut -d: -f1)"
  stale="$(grep -n 'ns_control_stop_watchman' "$PREFLIGHT" | cut -d: -f1)"
  clear="$(grep -n 'ns_control_drop_runtime_markers' "$PREFLIGHT" | cut -d: -f1)"
  [ -n "$active" ]
  [ "$active" -lt "$stale" ]
  [ "$stale" -lt "$clear" ]
  # The rule is policy, so Start keeps it; what a watchman verdict MEANS is the helper's to say.
  grep -qF 'never kill a live watchman' "$START"
  grep -qF 'never kill that watchman as stale' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  grep -qF 'A watchman is alive on this workspace' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'a watchman must never be able to advance the old lease' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
}

# Start opens the host reference only when a verdict names that host, so the reference has to
# carry the whole host answer — and stay host-neutral markdown, not a second skill.
@test "start host detail lives in one shared reference" {
  [ -f "$HOSTS" ]
  grep -qF 'start-hosts.md' "$START"
  grep -qF 'ConvertFrom-Json' "$HOSTS"
  grep -qF 'PSObject.Properties.Name' "$HOSTS"
  # Liveness is a verdict's meaning, not host detail: it moved onto the watchman explanation.
  grep -qF 'kill -0' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'process-evidence-unavailable' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'claude --resume' "$HOSTS"
  grep -qF 'codex resume' "$HOSTS"
  grep -qF 'agent --resume' "$HOSTS"
  # Linking another workspace and the stale-lease reset are repairs the helper hands the owner.
  grep -qF 'ns link-workspace' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  grep -qF 'ns_lease_reset_stale' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  grep -qF '$TASK_ROOT/.claude/settings.local.json' "$HOSTS"
  grep -qF '$TASK_ROOT/.claude/settings.json' "$HOSTS"
}

@test "stop writes the stop-work order through the trusted helper" {
  grep -qF '$NS/STOP' "$STOP"
  grep -qF '$NS/.watchman' "$STOP"
  grep -qF '$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns" stop-shift' "$STOP"
  grep -qi 'kill' "$STOP"
}

@test "stop panic commands use the bound Nightshift directory, not the working directory" {
  grep -qF 'touch "$NS/STOP"' "$STOP"
  grep -qF 'New-Item -ItemType File -Force "$NS\STOP"' "$STOP"
  grep -qF 'failed clock-out left a recovery nonce' "$STOP"
  if grep -qF 'New-Item -ItemType File -Force .nightshift\STOP' "$STOP"; then
    return 1
  fi
  if grep -qF 'touch .nightshift/STOP' "$STOP"; then
    return 1
  fi
}

@test "no skill uses a cwd-relative Windows STOP path" {
  if grep -R --include='SKILL.md' -F 'New-Item -ItemType File -Force .nightshift\STOP' "$SKILLS"; then
    echo "cwd-relative Windows STOP path in a skill" >&2
    return 1
  fi
}

@test "the STOP lever a refusal offers is an absolute path on both platforms" {
  # The panic form is a repair now, so it carries the resolved workspace rather than a name the
  # owner would have to expand themselves.
  grep -qF 'touch \"$NS/STOP\"' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/start-preflight.sh"
  grep -qF '$ns\STOP' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/start-preflight.ps1"
}

@test "hunt and quality arm with the same bound pair as start" {
  for f in "$START" "$HUNT" "$QUALITY"; do
    grep -qF 'touch "$NS/.shift-armed"' "$f" \
      || { echo "missing POSIX arm: $f"; return 1; }
    grep -qF 'New-Item -ItemType File -Force "$NS\.shift-armed"' "$f" \
      || { echo "missing Windows arm: $f"; return 1; }
    grep -qF 'ns" watchman' "$f" || grep -qF '`ns watchman`' "$f" \
      || { echo "does not arm the watchman through the dispatcher: $f"; return 1; }
  done
}

# Hunt and Quality start a shift without a second command. Naming only .shift-armed
# left Windows and Codex to invent a launcher; Start already ships the three.
@test "no skill picks the watchman for its host: one verb resolves to the right one" {
  for f in "$START" "$HUNT" "$QUALITY"; do
    for bad in 'runtime/claude/watchman.sh' 'runtime/codex/watchman.sh' \
      'runtime/cursor/watchman.sh' 'start-watchman.ps1'; do
      ! grep -qF -- "$bad" "$f" || { echo "names a host's watchman directly ($bad): $f"; return 1; }
    done
  done
  # And the helpers those verbs must reach still ship, one per host.
  for h in claude codex cursor; do
    [ -f "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/$h/watchman.sh" ] \
      || { echo "no watchman for $h"; return 1; }
  done
}

# The Codex watchman must not arm against an unsupported identity. Hunt's listed
# start steps used to jump from .shift-armed to the launcher.
@test "hunt and quality run the binding probe and Codex identity checkpoint before the watchman" {
  for f in "$START" "$HUNT" "$QUALITY"; do
    grep -qF ': nightshift-binding-probe' "$f" \
      || { echo "missing POSIX binding probe: $f"; return 1; }
    grep -qF "\$null = 'nightshift-binding-probe'" "$f" \
      || { echo "missing Windows binding probe: $f"; return 1; }
    grep -qF 'ns_codex_identity_kind' "$f" \
      || { echo "missing Codex identity helper: $f"; return 1; }
    grep -qF 'Get-NSCodexIdentityKind' "$f" \
      || { echo "missing Windows Codex identity helper: $f"; return 1; }
    grep -qF 'Nightshift.psm1' "$f" \
      || { echo "missing Windows module import: $f"; return 1; }
  done
}

@test "start and schedule inspect Claude settings at the task root" {
  grep -qF '.claude/settings.local.json' "$PREFLIGHT"
  grep -qF '.claude/settings.json' "$PREFLIGHT"
  grep -qF '.claude/settings.local.json' "$PREFLIGHT_PS1"
  grep -qF '$TASK_ROOT/.claude/settings.local.json' "$SCHEDULE"
  grep -qF '$TASK_ROOT/.claude/settings.json' "$SCHEDULE"
}

@test "setup writes gitignore and lists profiles on resolved roots" {
  grep -qF '$NIGHTSHIFT_WORKSPACE/.gitignore' "$SETUP"
  grep -qF '$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/profiles/' "$SETUP"
  grep -qF '$NIGHTSHIFT_PLUGIN_ROOT/skills/nightshift/references/nightshift-rules.schema.json' "$SETUP"
  grep -qF 'docs/knobs.md' "$SETUP"
}

@test "schedule reaches its generator as a verb, with one spelling of every flag" {
  grep -qF 'ns" schedule' "$SCHEDULE"
  grep -qF -- '`--list`' "$SCHEDULE"
  grep -qF -- '`--remove`' "$SCHEDULE"
  grep -qF -- "--agent 'codex exec -s danger-full-access'" "$SCHEDULE"
  # The PowerShell spellings are the dispatcher's business now, not the skill's.
  for bad in '-Project "$NIGHTSHIFT_WORKSPACE" -List' '`-List`' '`-Remove`'; do
    ! grep -qF -- "$bad" "$SCHEDULE" || { echo "carries a second spelling ($bad)"; return 1; }
  done
  grep -qF 'parked Hunt work order' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/schedule.ps1"
  grep -qF 'drafting-table item' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/schedule.ps1"
}

@test "Windows schedule generate names parked work on an empty list" {
  ps1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/schedule.ps1"
  grep -qF 'Note: the punch list has no open items' "$ps1"
  grep -qF 'Parked Hunt work orders:' "$ps1"
  grep -qF 'Drafting-table items:' "$ps1"
  awk '
    /if \(\$Preflight\)/ { pre=NR }
    /Note: the punch list has no open items/ { note=NR }
    /"Scheduled start for/ { start=NR }
    END { exit !(pre && note && start && pre < note && note < start) }
  ' "$ps1"
}

@test "no skill executable uses a cwd-relative marker or plugin helper" {
  if grep -R --include='SKILL.md' -E '`touch \.nightshift/' "$SKILLS"; then
    echo "cwd-relative POSIX nightshift command in a skill" >&2
    return 1
  fi
  if grep -R --include='SKILL.md' -F 'New-Item -ItemType File -Force .nightshift' "$SKILLS"; then
    echo "cwd-relative Windows nightshift command in a skill" >&2
    return 1
  fi
  if grep -R --include='SKILL.md' -F '`runtime\windows' "$SKILLS"; then
    echo "cwd-relative Windows runtime helper in a skill" >&2
    return 1
  fi
}

@test "doctor actions name helpers beside the inspector, not from cwd" {
  if grep -qF 'using runtime/' "$DOCTOR_SH"; then
    return 1
  fi
  if grep -qF 'with runtime/' "$DOCTOR_SH"; then
    return 1
  fi
  grep -qF '$_here/link-workspace.sh' "$DOCTOR_SH"
  grep -qF '$_here/migrate-state.sh' "$DOCTOR_SH"
  grep -qF '$_here/export-support.sh' "$DOCTOR_SH"
  grep -qF '$_here/stop-shift.sh' "$DOCTOR_SH"
}

@test "punch-list template STOP commands use the bound Nightshift directory" {
  tpl="$SKILLS/nightshift/references/punch-list-template.md"
  grep -qF 'touch "$NS/STOP"' "$tpl"
  grep -qF 'New-Item -ItemType File -Force "$NS\STOP"' "$tpl"
  if grep -qF 'touch .nightshift/STOP' "$tpl"; then
    return 1
  fi
  if grep -qF 'New-Item -ItemType File -Force .nightshift\STOP' "$tpl"; then
    return 1
  fi
}

@test "every helper a skill needs is reached, as a verb" {
  # The pairing this replaces held that a skill named both spellings of every helper. There is one
  # spelling now, so what is left to hold is that the skill still reaches the helper at all.
  for pair in \
    "doctor:doctor" "status:doctor" "import-issues:import-issues" "hunt:import-issues" \
    "archive:retain-history" "archive:archive-receipts" "setup:migrate-state" \
    "doctor:migrate-state" "setup:apply-profile" "doctor:apply-profile" \
    "doctor:export-support" "stop:stop-shift" "reset:reset-shift" "purge:purge-workspace" \
    "setup:write-receipt" "nightshift:write-receipt" \
    "nightshift:check-report"; do
    skill="${pair%%:*}"
    verb="${pair##*:}"
    grep -qF "ns\" $verb" "$SKILLS/$skill/SKILL.md" || grep -qF "\`ns $verb\`" "$SKILLS/$skill/SKILL.md" \
      || { echo "$skill does not reach $verb"; return 1; }
  done
  grep -qF 'ns" import-issues' "$REFS/shifts/github-issue-hunt.md"

  # Windows knowledge a dispatcher cannot carry: these are PowerShell language, not helpers.
  grep -qF 'Get-NSUnixTime' "$SKILLS/status/SKILL.md"
  grep -qF 'Get-NSReasonLabel' "$SKILLS/status/SKILL.md"
  grep -qF 'recorded pid' "$SKILLS/status/SKILL.md"
  grep -qF 'watchman pid' "$SKILLS/status/SKILL.md"
  grep -qF 'reimplement liveness' "$SKILLS/status/SKILL.md"

  # One spelling of every flag the import skill names.
  for flag in -- '--fetch' '--stage' '--allow-closed' '--repo owner/repo'; do
    [ "$flag" = -- ] && continue
    grep -qF -- "$flag" "$SKILLS/import-issues/SKILL.md" \
      || { echo "import-issues does not name $flag"; return 1; }
  done
}

@test "doctor Windows actions name helpers beside the inspector" {
  DOCTOR_PS1="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/doctor.ps1"
  grep -qF "Join-Path \$here 'migrate-state.ps1'" "$DOCTOR_PS1"
  grep -qF "Join-Path \$here 'export-support.ps1'" "$DOCTOR_PS1"
  grep -qF "Join-Path \$here 'link-workspace.ps1'" "$DOCTOR_PS1"
  grep -qF "Join-Path \$here 'write-receipt.ps1'" "$DOCTOR_PS1"
  grep -qF "Join-Path \$here 'stop-shift.ps1'" "$DOCTOR_PS1"
  grep -qF 'leftover Shift contract and Gates' "$DOCTOR_PS1"
  grep -qF 'pending Hunt work orders=' "$DOCTOR_PS1"
  grep -qF 'staged drafting-table items=' "$DOCTOR_PS1"
}

@test "setup substitutes workspace and NS tokens when copying owner files" {
  grep -qF 'substitute the resolved absolute workspace path for `$NIGHTSHIFT_WORKSPACE`' "$SETUP"
  grep -qF 'bound Nightshift directory for `$NS`' "$SETUP"
  grep -qF 'Never write those tokens into `rules.json`' "$SETUP"
}

@test "catalog prose uses Nightshift filenames, not a workspace prefix" {
  for f in "$SKILLS/nightshift/references"/catalog-recipe.md \
           "$SKILLS/nightshift/references"/execution-modes.md \
           "$SKILLS/nightshift/references"/gates-catalog.md \
           "$SKILLS/nightshift/references"/shift-catalog.md \
           "$SKILLS/nightshift/references/shifts"/*.md; do
    ! grep -qF '$NIGHTSHIFT_WORKSPACE/.nightshift/' "$f" \
      || { echo "catalog still prefixes workspace: $f"; return 1; }
  done
}

@test "skills do not repeat the workspace prefix after the NS bind" {
  python3 - "$SKILLS" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
bind = 'NS="$NIGHTSHIFT_WORKSPACE/.nightshift"'
for path in sorted(root.glob("*/SKILL.md")):
    text = path.read_text().replace(bind, "")
    if "$NIGHTSHIFT_WORKSPACE/.nightshift/" in text:
        raise SystemExit(f"repeated workspace prefix: {path}")
    if r"$NIGHTSHIFT_WORKSPACE\.nightshift" in text:
        raise SystemExit(f"repeated Windows workspace prefix: {path}")
PY
}

@test "Windows runtime helpers do not add a second toolchain" {
  if grep -RE 'brew |npm install|pip install|python3|jq is required' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"; then
    echo "Windows helper depends on a toolchain Nightshift does not ship" >&2
    return 1
  fi
}

@test "rules template keeps relative nightshift paths for owner editing" {
  rules="$SKILLS/nightshift/references/nightshift-rules-template.json"
  grep -qF '.nightshift/punch-list.md' "$rules"
  grep -qF '.nightshift/STOP' "$rules"
  if grep -qF '$NIGHTSHIFT_WORKSPACE' "$rules"; then
    return 1
  fi
}
