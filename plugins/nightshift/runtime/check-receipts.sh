#!/usr/bin/env bash
# check-receipts is check-report, kept so existing invocations keep working.
printf 'ns check-report\n' >&2
_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
exec "$_here/check-report.sh" "$@"
