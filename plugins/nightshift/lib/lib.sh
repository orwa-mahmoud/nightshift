#!/usr/bin/env bash
# lib.sh — shared hook helpers. Compatibility entry: source this file.
#
# Modules load in dependency order (no cycles):
#   common.sh     generic shell helpers
#   paths.sh      workspace / canonical path resolution
#   git.sh        Git inspection and commit-safety
#   rules-read.sh strict-subset reader for rules.json
#   state.sh      runtime files (rules, punch list, schema, retention)
#   policy.sh     the shift-policy resolver (rules, defaults, tonight's snapshot)
#   usage.sh      what a shift cost, read from the records each host already keeps
#   process.sh    process evidence
#   ownership.sh  locks, session, lease, shift fencing
#
# Callers keep sourcing lib.sh. Do not source the modules directly.
#
# Source-time contract: NS_STATE_VERSION is set when state.sh loads.
# Call-time globals stay with the functions that set them (NS_LEASE_*, NS_CURRENT_*,
# NS_GIT_PROSP_DIR, GIT_INDEX_FILE, NS_SHIFT_*).

# Resolve modules next to this file, independent of the caller's cwd.
# Pure-bash path: no dirname (hostile PATH).
_ns_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_ns_lib_dir" != "${BASH_SOURCE[0]}" ] || _ns_lib_dir=.
# shellcheck source=plugins/nightshift/lib/common.sh
. "$_ns_lib_dir/common.sh"
# shellcheck source=plugins/nightshift/lib/paths.sh
. "$_ns_lib_dir/paths.sh"
# shellcheck source=plugins/nightshift/lib/git.sh
. "$_ns_lib_dir/git.sh"
# shellcheck source=plugins/nightshift/lib/rules-read.sh
. "$_ns_lib_dir/rules-read.sh"
# shellcheck source=plugins/nightshift/lib/state.sh
. "$_ns_lib_dir/state.sh"
# shellcheck source=plugins/nightshift/lib/policy.sh
. "$_ns_lib_dir/policy.sh"
# shellcheck source=plugins/nightshift/lib/usage.sh
. "$_ns_lib_dir/usage.sh"
# shellcheck source=plugins/nightshift/lib/process.sh
. "$_ns_lib_dir/process.sh"
# shellcheck source=plugins/nightshift/lib/ownership.sh
. "$_ns_lib_dir/ownership.sh"
# shellcheck source=plugins/nightshift/lib/evidence-lifecycle.sh
. "$_ns_lib_dir/evidence-lifecycle.sh"
unset _ns_lib_dir
