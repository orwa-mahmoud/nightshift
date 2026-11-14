# Security Policy

## Supported versions

Only the latest release is supported. Nightshift itself has no telemetry and
does not phone home. A running shift does launch the coding agent selected by
the owner (`claude`, `codex`, or Cursor's `agent`), whose own network behaviour
and policies still apply. If the owner configures `notifyCommand`, Nightshift also executes that
command locally at the documented shift-ending or recovery-failure events; the
command may access the network because it is unrestricted owner-provided shell.

The primary Nightshift attack surface is therefore its local hook and runtime
scripts, the permissions granted to the coding agent, and any owner-configured
notification command.

## Reporting

A public issue is the default. Nightshift is a local plugin: gate, hardhat,
knobs, receipts, and other local guard misses belong in the open, including a
bound agent that can defeat its own contract. A commit-guard hole that lets the
night stage a file it can already read is still a public hardening report.

A private advisory is optional. Use it when a report could leak secrets off this
machine, reach other users, or compromise something beyond this owner's agent
or session. The form is here:
[Report a vulnerability](https://github.com/orwa-mahmoud/nightshift/security/advisories/new).

A failed or interrupted night that is not a new hardening report belongs on a
[Failed shift](https://github.com/orwa-mahmoud/nightshift/issues/new?template=failed_shift.yml)
report. That form asks for host/version and sanitized markers; it must not
include prompts, credentials, repository content, or a full transcript.

When reporting, please include:

- The coding agent (Claude Code, Codex, or Cursor), its version, and the plugin version.
- The operating system and shell version.
- A minimal reproduction.

You'll get a reply within a week.
