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

## What the runtime needs

The plugin is shell scripts, PowerShell scripts, and Markdown. It ships no binary and installs no
package. macOS and Linux use Bash 3.2 or later with the standard POSIX tools; native Windows uses
PowerShell 5.1 or later. Git is needed for a shift that works a repository. On POSIX, `jq` or
`python3` reads JSON when present, and neither is required to enforce the owner's rules.

## Tightening an unattended shift

Beyond protecting its own state files, Nightshift restricts only what the owner chooses: a shift
can do what the host session allows. The owner narrows it in `.nightshift/rules.json`, and the
hooks enforce those rules in every permission mode:

- `forbiddenCommands` denies a command that matches a pattern, such as `git push`.
- `protectedDirs` keeps named directories out of `git add` and every commit.
- `neverCommitPatterns` refuses a commit whose diff matches a pattern, such as a key or a password.
- `expectedEmail` refuses a commit made under another identity.
- `toolDeny` denies named host tools.
- `elevation` covers five categories that create system state (`sudo`, `containers`,
  `global-packages`, `daemons`, `external-services`), each allowed or denied by the owner.

Three shipped profiles set common combinations: `no-push`, `isolated-branch`, and
`strict-secrets`. `ns apply-profile` previews a profile and writes it only with `--apply`.
[Owner knobs](docs/knobs.md) lists every setting. These guards are hardening, not a sandbox.

## Secrets

During a shift the agent can neither read nor rewrite `rules.json`. `neverCommitPatterns` and
`protectedDirs` keep credentials out of commits. The support bundle that `ns export-support`
writes leaves known sensitive fields out, stays on the machine, and is never uploaded.

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
