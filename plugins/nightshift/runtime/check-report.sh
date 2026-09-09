#!/usr/bin/env bash
# check-report is now check-receipts.
printf 'ns check-receipts\n' >&2
_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
exec "$_here/check-receipts.sh" "$@"
