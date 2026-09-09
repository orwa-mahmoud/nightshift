#!/usr/bin/env bash
# apply-profile.sh — preview or copy a shipped local rules profile.
#
# One-time local copy. No network, no subscription, no overwrite in fill mode.
#   apply-profile.sh [--project DIR] --list
#   apply-profile.sh [--project DIR] --profile NAME --mode replace|fill [--apply]
#
# Default is preview. --apply writes only while unarmed.
# Profile schema v2 (name, version 2, risk, use, rules, shiftDefaults, gates) additionally
# previews/writes the shift block of .nightshift/rules.json, which is where the remembered
# choices live (merged over whatever is already there — only the profile's own fields change) and rewrites the punch list's `## Gates` block (the text
# between the `## Gates` heading and the next `## ` heading): an empty itemGate writes the
# template placeholder, a non-empty one renders the item gate and site inspection commands.
# `shiftDefaults: null` or `gates: null` leaves that file/block untouched. Version-1 profiles
# (rules only) keep working exactly as before.
# Exit: 0 previewed or applied · 1 usage · 2 refused
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROFILES="$_here/../skills/nightshift/references/profiles"
SCHEMA="$_here/../skills/nightshift/references/nightshift-rules.schema.json"
TEMPLATE="$_here/../skills/nightshift/references/nightshift-rules-template.json"
PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
MODE=""
PROFILE=""
APPLY=0
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || exit 1; PROJECT="$2"; shift 2 ;;
    --profile) [ $# -ge 2 ] || exit 1; PROFILE="$2"; shift 2 ;;
    --mode) [ $# -ge 2 ] || exit 1; MODE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --list) LIST=1; shift ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'apply-profile: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

HOST="$(cd -P "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'apply-profile: cannot cd to %s\n' "$PROJECT" >&2
  exit 1
}
WORKSPACE="$HOST"
if [ -e "$HOST/.nightshift-link" ] || [ -L "$HOST/.nightshift-link" ]; then
  WORKSPACE="$(ns_workspace_root "$HOST" 2>/dev/null)" || {
    printf 'apply-profile: invalid .nightshift-link\n' >&2
    exit 2
  }
fi
NS="$WORKSPACE/.nightshift"
RULES="$NS/rules.json"
DEFAULTS_PATH="$NS/shift-defaults.json"
PUNCHLIST="$NS/punch-list.md"

if [ "$LIST" -eq 1 ]; then
  printf 'Nightshift rule profiles (local copies, not a subscription)\n'
  for f in "$PROFILES"/*.json; do
    [ -f "$f" ] || continue
    if command -v jq >/dev/null 2>&1; then
      jq -r '"  \(.name)  risk=\(.risk)  v\(.version)  \(.use)"' "$f"
    else
      printf '  %s\n' "${f##*/}"
    fi
  done
  exit 0
fi

case "$MODE" in
  replace | fill) ;;
  *) printf 'apply-profile: --mode must be replace or fill\n' >&2; exit 1 ;;
esac
case "$PROFILE" in
  '' | *[!A-Za-z0-9_-]*)
    printf 'apply-profile: unknown profile %s\n' "$PROFILE" >&2
    exit 1
    ;;
esac
SRC="$PROFILES/${PROFILE}.json"
[ -f "$SRC" ] || {
  printf 'apply-profile: unknown profile %s\n' "$PROFILE" >&2
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'apply-profile: jq is required to preview and apply profiles\n' >&2
  exit 2
fi

if ! jq -e '.name and (.version == 1 or .version == 2) and .rules and (.rules | type == "object")' "$SRC" >/dev/null 2>&1; then
  printf 'apply-profile: profile is malformed or not version 1 or 2\n' >&2
  exit 2
fi
VERSION="$(jq -r '.version' "$SRC")"

unknown="$(jq -r --slurpfile s "$SCHEMA" '
  .rules | keys[] as $k
  | select(($s[0].properties | has($k) | not) or $k == "$schema")
  | $k
' "$SRC")"
if [ -n "$unknown" ]; then
  printf 'apply-profile: profile has unsupported keys: %s\n' "$unknown" >&2
  exit 2
fi

SD_TYPE=""
GATES_TYPE=""
if [ "$VERSION" = "2" ]; then
  SD_TYPE="$(jq -r '.shiftDefaults | type' "$SRC")"
  case "$SD_TYPE" in
    null | object) ;;
    *) printf 'apply-profile: profile shiftDefaults must be null or an object\n' >&2; exit 2 ;;
  esac
  GATES_TYPE="$(jq -r '.gates | type' "$SRC")"
  case "$GATES_TYPE" in
    null | object) ;;
    *) printf 'apply-profile: profile gates must be null or an object\n' >&2; exit 2 ;;
  esac

  if [ "$SD_TYPE" = "object" ]; then
    unknown_sd="$(jq -r '
      .shiftDefaults | keys[] as $k
      | select((["verificationProfile","hours","toolingPolicy","execution"] | index($k)) == null)
      | $k
    ' "$SRC")"
    [ -z "$unknown_sd" ] || {
      printf 'apply-profile: profile shiftDefaults has unsupported keys: %s\n' "$unknown_sd" >&2
      exit 2
    }
    VP="$(jq -r '.shiftDefaults.verificationProfile // empty' "$SRC")"
    if [ -n "$VP" ]; then
      case "$VP" in
        fast | balanced | strict | custom) ;;
        *)
          printf 'apply-profile: profile shiftDefaults.verificationProfile must be fast, balanced, strict, or custom\n' >&2
          exit 2
          ;;
      esac
    fi
    HOURS_TYPE="$(jq -r 'if (.shiftDefaults | has("hours")) then (.shiftDefaults.hours | type) else "absent" end' "$SRC")"
    case "$HOURS_TYPE" in
      absent | null | number) ;;
      *) printf 'apply-profile: profile shiftDefaults.hours must be an integer or null\n' >&2; exit 2 ;;
    esac
    TP="$(jq -r '.shiftDefaults.toolingPolicy // empty' "$SRC")"
    if [ -n "$TP" ]; then
      case "$TP" in
        existing-tools | review-missing | auto-add) ;;
        *)
          printf 'apply-profile: profile shiftDefaults.toolingPolicy must be existing-tools, review-missing, or auto-add\n' >&2
          exit 2
          ;;
      esac
    fi
    EXEC="$(jq -r '.shiftDefaults.execution // empty' "$SRC")"
    if [ -n "$EXEC" ]; then
      case "$EXEC" in
        review-first | run-direct) ;;
        *) printf 'apply-profile: profile shiftDefaults.execution must be review-first or run-direct\n' >&2; exit 2 ;;
      esac
    fi
  fi

  if [ "$GATES_TYPE" = "object" ]; then
    if ! jq -e '(.gates.itemGate | type) == "array" and (.gates.itemGate | all(type == "string"))' "$SRC" >/dev/null 2>&1; then
      printf 'apply-profile: profile gates.itemGate must be an array of command strings\n' >&2
      exit 2
    fi
    SI_PRESENT="$(jq -r '.gates | has("siteInspection")' "$SRC")"
    if [ "$SI_PRESENT" = "true" ]; then
      SI_TYPE="$(jq -r '.gates.siteInspection | type' "$SRC")"
      [ "$SI_TYPE" = "object" ] || {
        printf 'apply-profile: profile gates.siteInspection must be an object\n' >&2
        exit 2
      }
      EVERY="$(jq -r '.gates.siteInspection.every // empty' "$SRC")"
      case "$EVERY" in
        *' items') EVERY_N="${EVERY% items}" ;;
        *' hours') EVERY_N="${EVERY% hours}" ;;
        *) EVERY_N="" ;;
      esac
      case "$EVERY_N" in
        '' | *[!0-9]*)
          printf 'apply-profile: profile gates.siteInspection.every must be "N items" or "H hours"\n' >&2
          exit 2
          ;;
      esac
      if ! jq -e '(.gates.siteInspection.commands | type) == "array" and (.gates.siteInspection.commands | all(type == "string"))' "$SRC" >/dev/null 2>&1; then
        printf 'apply-profile: profile gates.siteInspection.commands must be an array of command strings\n' >&2
        exit 2
      fi
    fi
  fi
fi

[ -d "$NS" ] || {
  printf 'apply-profile: no .nightshift/ — run setup first\n' >&2
  exit 2
}

if [ -f "$NS/.shift-armed" ] && [ "$APPLY" -eq 1 ]; then
  printf 'apply-profile: refuse to write rules while the shift is armed\n' >&2
  exit 2
fi

if [ "$APPLY" -eq 1 ] && [ "$GATES_TYPE" = "object" ]; then
  [ -f "$PUNCHLIST" ] || {
    printf 'apply-profile: no punch-list.md — run setup first\n' >&2
    exit 2
  }
  grep -q '^## Gates$' "$PUNCHLIST" || {
    printf 'apply-profile: punch-list.md has no "## Gates" heading\n' >&2
    exit 2
  }
fi

current='{}'
if [ -f "$RULES" ] && jq -e 'type == "object"' "$RULES" >/dev/null 2>&1; then
  current="$(cat "$RULES")"
fi

proposed="$(PROFILE_MODE="$MODE" jq -n --argjson cur "$current" \
  --slurpfile p "$SRC" --slurpfile t "$TEMPLATE" '
  def fill:
    ($cur)
    + (
        $p[0].rules
        | to_entries
        | map(select(($cur[.key] | not)))
        | from_entries
      );
  def replace:
    $t[0]
    + $p[0].rules
    + (
        if ($cur["$schema"] | type) == "string" and ($cur["$schema"] | length) > 0
        then {"$schema": $cur["$schema"]}
        else {}
        end
      )
    # Replace rebuilds the guards from the shipped template. It does not reach into the owner
    # preference blocks, which no guard profile is asking about: a profile that forbids a push
    # has nothing to say about the verification cadence or where archives are filed, and
    # resetting those would take away a choice nobody made here.
    + (["shift", "handoff", "archive", "recovery", "receipts"]
       | map(select($cur[.] != null) | {(.): $cur[.]})
       | add // {});
  if env.PROFILE_MODE == "fill" then fill else replace end
')"

if ! printf '%s' "$proposed" | jq -e '
  (.toolDeny | type) == "object"
  and (.toolDeny | has("AskUserQuestion"))
  and (.toolDeny | has("request_user_input"))
  and (.toolDeny | has("AskQuestion"))
  and (.toolDeny.AskUserQuestion | type) == "string"
  and (.toolDeny.request_user_input | type) == "string"
  and (.toolDeny.AskQuestion | type) == "string"
' >/dev/null 2>&1; then
  printf 'apply-profile: proposed rules lack an explicit native question policy — re-run setup first\n' >&2
  exit 2
fi

# The base a profile merges over: what the owner file's shift block already holds, else the older
# defaults file where a workspace still has one, else the built-ins. Reading the canonical block
# first is what makes "only the profile's own fields change" true — merging over the built-ins
# would quietly reset a field the last profile set.
shift_defaults_base() {
  builtin='{"schemaVersion":1,"verificationProfile":"fast","hours":null,"toolingPolicy":"existing-tools","execution":"review-first"}'
  block=""
  if [ -f "$RULES" ]; then
    block="$(jq -c 'if (.shift | type) == "object" then (.shift + {schemaVersion: 1}) else empty end' \
      "$RULES" 2>/dev/null)" || block=""
  fi
  if [ -n "$block" ]; then
    printf '%s' "$builtin" | jq -c --argjson over "$block" '. + $over'
    return 0
  fi
  if [ -f "$DEFAULTS_PATH" ] && jq -e '
      type == "object"
      and .schemaVersion == 1
      and (.verificationProfile as $v | (["fast","balanced","strict","custom"] | index($v)) != null)
      and (.hours == null or (.hours | type == "number"))
      and (.toolingPolicy as $t | (["existing-tools","review-missing","auto-add"] | index($t)) != null)
      and (.execution as $e | (["review-first","run-direct"] | index($e)) != null)
    ' "$DEFAULTS_PATH" >/dev/null 2>&1
  then
    cat "$DEFAULTS_PATH"
  else
    printf '%s' "$builtin"
  fi
}

# Merge the profile's shiftDefaults over the base — only the keys the profile sets change.
merged_shift_defaults() {
  base="$1"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --argjson base "$base" --slurpfile p "$SRC" --arg now "$now" '
    ($p[0].shiftDefaults // {}) as $sd
    | $base
    + (if ($sd | has("verificationProfile")) then {verificationProfile: $sd.verificationProfile} else {} end)
    + (if ($sd | has("hours")) then {hours: $sd.hours} else {} end)
    + (if ($sd | has("toolingPolicy")) then {toolingPolicy: $sd.toolingPolicy} else {} end)
    + (if ($sd | has("execution")) then {execution: $sd.execution} else {} end)
    + {schemaVersion: 1, updatedAt: $now}
  '
}

# The rendered `## Gates` block body: the placeholder for an empty itemGate, else the item gate
# commands in the template's phrasing, plus the site inspection sentence when that key is
# present (a profile that omits siteInspection gets no site-inspection sentence at all).
render_gates_body() {
  item_count="$(jq '.gates.itemGate | length' "$SRC")"
  if [ "$item_count" -eq 0 ]; then
    printf '_None configured._'
    return 0
  fi
  printf '**Item gate** — runs every item, right before its commit or artifact receipt:\n\n'
  jq -r '.gates.itemGate[] | "- `" + . + "`"' "$SRC"
  si_present="$(jq -r '.gates | has("siteInspection")' "$SRC")"
  if [ "$si_present" = "true" ]; then
    printf '\n'
    every="$(jq -r '.gates.siteInspection.every' "$SRC")"
    printf '**Site inspection** — the heavier batch, every %s:\n' "$every"
    site_count="$(jq '.gates.siteInspection.commands | length' "$SRC")"
    if [ "$site_count" -eq 0 ]; then
      printf '\n_None configured._'
    else
      printf '\n'
      jq -r '.gates.siteInspection.commands[] | "- `" + . + "`"' "$SRC"
    fi
  fi
}

printf 'Profile: %s\n' "$(jq -r '.name' "$SRC")"
printf 'Risk:    %s\n' "$(jq -r '.risk' "$SRC")"
printf 'Use:     %s\n' "$(jq -r '.use' "$SRC")"
printf 'Mode:    %s\n' "$MODE"
printf 'Rules the profile sets:\n'
jq -r '.rules | to_entries[] | "  \(.key)=\(.value|tojson)"' "$SRC"
printf '\nProposed rules.json\n'
printf '%s\n' "$proposed" | jq -S .

if [ "$SD_TYPE" = "object" ]; then
  base="$(shift_defaults_base)"
  merged="$(merged_shift_defaults "$base")"
  printf '\nProposed shift-defaults.json\n'
  printf '%s\n' "$merged" | jq -S .
fi

if [ "$GATES_TYPE" = "object" ]; then
  printf '\nProposed ## Gates block\n%s\n' "$(render_gates_body)"
fi

if [ "$APPLY" -eq 0 ]; then
  printf '\nDry run. Re-run with --apply after explicit confirmation.\n'
  exit 0
fi

tmp="$NS/.rules.json.$$"
printf '%s\n' "$proposed" | jq -S . >"$tmp" || {
  rm -f "$tmp"
  exit 2
}
mv "$tmp" "$RULES" || {
  rm -f "$tmp"
  exit 2
}
printf 'Wrote %s\n' "$RULES"

if [ "$SD_TYPE" = "object" ]; then
  # The remembered choices live in the shift block of the owner file. A profile writes them where
  # they are read from, so applying one cannot split the same setting across two files.
  base="$(shift_defaults_base)"
  merged="$(merged_shift_defaults "$base")"
  block="$(printf '%s' "$merged" | jq -c 'del(.schemaVersion, .updatedAt)')" || exit 2
  tmp_sd="$NS/.rules-with-shift.json.$$"
  ns_rules_set_block "$RULES" shift "$block" >"$tmp_sd" || {
    rm -f "$tmp_sd"
    exit 2
  }
  ns_rules_load "$tmp_sd" >/dev/null 2>&1 || {
    rm -f "$tmp_sd"
    printf 'apply-profile: the updated owner file would not load\n' >&2
    exit 2
  }
  mv "$tmp_sd" "$RULES" || {
    rm -f "$tmp_sd"
    exit 2
  }
  printf 'Wrote the shift block of %s\n' "$RULES"
fi

if [ "$GATES_TYPE" = "object" ]; then
  gates_line="$(grep -n '^## Gates$' "$PUNCHLIST" | head -1 | cut -d: -f1)"
  total_lines="$(wc -l <"$PUNCHLIST" | tr -d ' ')"
  next_line="$(awk -v start="$gates_line" 'NR > start && /^## / { print NR; exit }' "$PUNCHLIST")"
  [ -n "$next_line" ] || next_line=$((total_lines + 1))
  body="$(render_gates_body)"
  tmp_pl="$NS/.punch-list.md.$$"
  {
    head -n "$gates_line" "$PUNCHLIST"
    printf '\n'
    printf '<!-- Nightshift Setup fills this from your stack, or leaves it empty (no automated checks).\n'
    printf '     Item gate: runs every item, right before its commit or artifact receipt — must be green to tick.\n'
    printf '     Site inspection: the heavier batch (coverage, dead code, Sonar), every N items or H hours. -->\n'
    printf '\n'
    printf '%s\n' "$body"
    printf '\n'
    tail -n +"$next_line" "$PUNCHLIST"
  } >"$tmp_pl" || {
    rm -f "$tmp_pl"
    exit 2
  }
  mv "$tmp_pl" "$PUNCHLIST" || {
    rm -f "$tmp_pl"
    exit 2
  }
  printf 'Wrote %s\n' "$PUNCHLIST"
fi

exit 0
