#!/usr/bin/env bash
# check-receipts — with --diagrams, a report on the receipts of ticked items: while
# receipts.evidence.architecture is on, each one with no `Diagram:` line. Report only; nothing
# blocks a tick, and with the diagram off there is nothing to report. Without --diagrams it is
# check-report, kept under this name so existing invocations keep working.
#
#   check-receipts.sh --project DIR --diagrams
#
# Exit: 0 checked · 1 usage
_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
case " $* " in
  *' --diagrams '*) ;;
  *)
    printf 'ns check-report\n' >&2
    exec "$_here/check-report.sh" "$@"
    ;;
esac
set -u
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'check-receipts: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --diagrams) shift ;;
    *) printf 'check-receipts: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'check-receipts: no workspace at %s\n' "$PROJECT" >&2; exit 1; }

ticked="$(ns_item_rows "$(ns_layout_path "$WORKSPACE/.nightshift" punch-list)" ticked | grep -c . || true)"
missing="$(ns_architecture_missing "$WORKSPACE")"
with=0
while IFS= read -r label; do
  [ -n "$label" ] || continue
  printf '%s: no Diagram: line\n' "$label"
  with=$((with + 1))
done <<EOF
$missing
EOF
printf 'checked %s ticked items: %s with findings\n' "${ticked:-0}" "$with"
exit 0
