# Install

Nightshift installs as a native plugin from this repository's marketplace, with no separate app,
service, or API key. Install it once, then run [your first shift](../README.md#your-first-shift).

## Claude Code

Run inside Claude Code:

```text
/plugin marketplace add orwa-mahmoud/nightshift
/plugin install nightshift@nightshift
```

## Codex

```text
codex plugin marketplace add orwa-mahmoud/nightshift
codex plugin add nightshift@nightshift
```

Add the marketplace once per Codex installation. Then review and trust the plugin's hooks,
with `/hooks` in the CLI or, in the Codex app, the **Review hooks** button (the hook icon in the
message box) or **Settings → Hooks**.

Open the project you want Nightshift to change, or connect Codex to its GitHub repository.

## Cursor

Open **Customize → Add → From GitHub Repository**, paste
`https://github.com/orwa-mahmoud/nightshift`, choose a scope, and select **Import**. Then select
Nightshift from the imported marketplace to install it. The
[Cursor Directory listing](https://cursor.directory/plugins/nightshift) links here for discovery.

## The skills-only edition for ChatGPT

The [OpenAI Plugin Directory](https://chatgpt.com/plugins/plugins_6a7c58f65d708191b3a705a8625baffe)
lists a skills-only edition. It works the punch list, receipts, and parked decisions with the
session's own tools, but the directory does not accept
[lifecycle hooks](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks),
so it has no clock-out gate, recovery, or usage accounting. Use it while you watch the session, and
the full plugin for a shift you leave alone. Its Setup offers the full plugin; once that is
installed, turn the directory copy off so only one Nightshift is enabled.

A ChatGPT chat with no project behind it cannot keep project changes, so Setup sends you to Codex
before it writes anything.

## skills.sh

```text
npx skills add https://github.com/orwa-mahmoud/nightshift --skill install-nightshift
```

This adds one small skill that installs the full plugin into Claude Code, Codex, or Cursor.

## Platforms

macOS and Linux use the bundled Bash runtime. Native Windows uses bundled PowerShell, with no Git
Bash or WSL needed. Under WSL, keep the host, the plugin, the repository, and the watchman in one
Linux distribution. [Native Windows](windows.md#native-windows) and
[Remote environments](remote-environments.md#remote-ssh-and-devcontainers) cover the details.

[Your first shift](../README.md#your-first-shift) · [Setup](setup.md#setup) ·
[Troubleshooting](troubleshooting.md#troubleshooting) · [Documentation index](README.md#documentation)
