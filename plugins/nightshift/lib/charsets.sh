#!/usr/bin/env bash
# charsets.sh — the ASCII characters name and id checks accept.
#
# A bracket range in a shell pattern follows the locale's collation in bash 3.2, the macOS
# /bin/bash: under en_US.UTF-8, [a-z] also matches A, é and ß, and [0-9a-f] matches ABC. These
# helpers spell the characters out, so a check means the same in every locale. Needs nothing else,
# so any file may source it on its own.

# ns_ascii_set <var> <class>... — set var to the characters of the classes: lower, upper, digit,
# hex (0-9 and a-f), or any other word taken literally, such as ._-
ns_ascii_set() {
  local _ns_set="" _ns_class
  for _ns_class in "${@:2}"; do
    case "$_ns_class" in
      lower) _ns_set="${_ns_set}abcdefghijklmnopqrstuvwxyz" ;;
      upper) _ns_set="${_ns_set}ABCDEFGHIJKLMNOPQRSTUVWXYZ" ;;
      digit) _ns_set="${_ns_set}0123456789" ;;
      hex) _ns_set="${_ns_set}0123456789abcdef" ;;
      *) _ns_set="$_ns_set$_ns_class" ;;
    esac
  done
  printf -v "$1" '%s' "$_ns_set"
}

# ns_ascii_only <value> <class>... — true when every character of value is in the classes, as
# ns_ascii_set reads them. An empty value passes; a caller that needs one tests for it.
ns_ascii_only() {
  local allowed
  ns_ascii_set allowed "${@:2}"
  [ -n "$allowed" ] || {
    printf 'ns_ascii_only: no character class given\n' >&2
    return 2
  }
  case "$1" in *[!"$allowed"]*) return 1 ;; esac
}
