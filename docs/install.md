# Install

Nightshift installs as a plugin from this repository's marketplace on every host. After
installing, run a [first shift](../README.md#your-first-shift).

## Codex and ChatGPT

**Recommended: the full plugin for local Codex.** Install it from the repository marketplace:

```text
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Add the marketplace once per Codex installation. Review and trust the plugin's hooks (`/hooks` in
the CLI), then start a new conversation. The full plugin carries the clock-out gate, safety rules,
session recovery, and per-item token usage and time.

**Skills-only edition.** The
[official OpenAI Plugin Directory listing](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
works the punch list, receipts, parked decisions and continuation notes with the session's own
tools. Directory versions up to 0.25.3 carry the full plugin; later versions are skills-only,
because the directory does not accept
[lifecycle hooks](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks).
It has no clock-out gate, recovery or usage accounting, so it suits attended sessions and ChatGPT.
Its Setup offers the full plugin; after installing it, turn the directory copy off so one
Nightshift is enabled.

Open the project you want Nightshift to change in Codex, or connect Codex to its GitHub repository.
A Git repository or a persistent local folder works. A disposable ChatGPT scratch conversation
cannot preserve project changes, so Setup redirects you to Codex before writing run state.

## Claude Code

Run inside Claude Code:

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift
```

## Cursor

Open **Customize → Add → From GitHub Repository**, paste
`https://github.com/orwa-mahmoud/nightshift`, choose a scope, and select **Import**.
Then select Nightshift from the imported marketplace to install it.
The [Cursor Directory listing](https://cursor.directory/plugins/nightshift) is for discovery;
installation happens inside Cursor. Read the host-specific
[recovery and CLI limitations](how-it-works.md#recovery) before starting a shift.

## skills.sh

```text
npx skills add https://github.com/orwa-mahmoud/nightshift --skill install-nightshift
```

This adds one small skill, kept in this repository's root `skills/` folder, that installs the full
plugin into Claude Code, Codex or Cursor. Nightshift's own skills need its hooks and runtime, so
they are marked internal and install only as part of the plugin.

## Platforms

macOS and Linux use the bundled Bash runtime. Native Windows uses bundled PowerShell, with no
Git Bash or WSL required. For WSL, keep the host, plugin, repository, and watchman in one Linux
distribution. See [Native Windows](windows.md#native-windows) and
[Remote environments](remote-environments.md#remote-ssh-and-devcontainers) for platform details.

[Run a first shift](../README.md#your-first-shift) · [Troubleshooting](troubleshooting.md#troubleshooting) ·
[Documentation index](README.md#documentation)
