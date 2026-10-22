---
name: install-nightshift
description: Install the full Nightshift plugin, with its hooks and runtime, into Claude Code, Codex or Cursor.
---

# Install Nightshift

Nightshift is a plugin, not a standalone skill. Its skills call a bundled runtime and depend on
hooks: the clock-out gate, the guard and the usage accounting. A copied skill folder carries none
of that, so this skill installs the real plugin from its marketplace,
`https://github.com/orwa-mahmoud/nightshift`, on each host the user wants it on.

## 1. Read what is installed

Check each host that exists on this machine. A host whose CLI is not on `PATH` and whose folder is
absent is not installed. Skip it.

| Host | Present when | Nightshift installed when |
| --- | --- | --- |
| Claude Code | `claude` runs | `claude plugin list` shows `nightshift@nightshift` |
| Codex | `codex` runs | `codex plugin list` shows a `nightshift@…` entry `installed` |
| Cursor | `~/.cursor` exists | `~/.cursor/plugins/cache/` holds a folder with `nightshift` in its name |

On Windows, `~` is `%USERPROFILE%`. Report each host on one line: absent, present without
Nightshift, or present with Nightshift and its version.

**One copy per host.** Codex can hold two Nightshift copies, for example a directory install and
the marketplace one. Two enabled copies both run their hooks, and Start refuses the shift. When a
host shows two, name both with their versions, keep the `nightshift@nightshift` copy, and give the
user the command to remove the other, such as `codex plugin remove nightshift@<other-marketplace>`.
Never add a copy beside an existing one.

## 2. Install on this host first

Install on the host you are running in, unless it already has Nightshift. For an older version,
update it instead.

- **Claude Code**

  ```bash
  claude plugin marketplace add orwa-mahmoud/nightshift
  claude plugin install nightshift@nightshift
  ```

  Update: `claude plugin marketplace update nightshift`, then
  `claude plugin update nightshift@nightshift`.

- **Codex**

  ```bash
  codex plugin marketplace add orwa-mahmoud/nightshift
  codex plugin add nightshift@nightshift
  ```

  Update: `codex plugin marketplace upgrade nightshift`.

- **Cursor** installs plugins in its own window. Give the user these steps: open
  **Customize → Add → From GitHub Repository**, paste `https://github.com/orwa-mahmoud/nightshift`,
  choose a scope, select **Import**, then select Nightshift from the imported marketplace.

A marketplace that is already added makes `marketplace add` report it. That is not a failure;
continue with the install.

## 3. Offer the other hosts

For each other host that is present without Nightshift, ask once whether to set it up as well,
and install only on a yes. Never install on a host the user did not agree to.

## 4. Say what each host still needs

Finish with one line per host you touched:

- **Claude Code:** restart Claude Code to load the plugin.
- **Codex:** review and trust the plugin's hooks with `/hooks`, then start a new conversation.
- **Cursor:** start a new agent chat once Nightshift shows as installed.

Then name the first step: open the project Nightshift should work on, and run Setup
(`/nightshift:setup` on Claude Code and Cursor, `$nightshift:setup` on Codex).

If a command fails, show its output and stop on that host. Do not retry with other flags.
