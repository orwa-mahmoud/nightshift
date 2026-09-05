# Owner knobs

The scaffolded rules file carries every supported key. Optional guards are off until you set them;
the three explicit question-tool entries default to parking so an unattended shift does not wait
for the owner.

The contract itself is a knob too: the punch-list text above `## Items` and the rules file's
`clockOutMessage` are the owner's words. The shipped default asks one commit per item in
repository mode, and in artifact mode completes an item with its section in the shift report — but
the gate releases on ticks, and the stall guard counts a tick as progress on its own, so a contract
with the commit rule stripped runs a full night with no commits at all (on Codex, such a night
needs only the `workspace-write` sandbox).

**One file drives them all:** setup copies a ready template to `.nightshift/rules.json` —
clean JSON, yours to edit: the tool-deny map, the guard patterns, the cadences, the watchman's
revival orders, the gate's clock-out text. The hooks read the file directly on every tool call,
so an edit applies from your very next action — no sync, no restart, no second copy. During a
shift the file itself is guarded: the session working the night is denied touching it, so only
you set or lift a rule. The env vars below remain as session-start overrides for tests and
one-off exceptions.

## Where a setting comes from

A setting has one permanent home and one place it may be varied for a single night. Four sources
decide the value in force, in this order:

1. **The built-in default.** What the plugin does when no file says anything.
2. **`.nightshift/rules.json`.** Your permanent answer. A key you wrote is your answer even when
   its value is an empty string or a zero — that reads as `rules`/`permanent`, not as silence.
3. **The shift snapshot**, `.nightshift/shift-policy.json`. The resolved policy for the night that
   is running, written before the gate arms and guarded once it is. It carries the deadline, the
   verification level, the tooling policy, the completion mode, and any elevation the owner
   granted for that shift alone. It is a record, not a second settings file.
4. **Your host's permission boundary**, which is a ceiling rather than a step. Claude Code, Codex,
   and Cursor each decide what the agent may do at all; no Nightshift key lifts that, and an
   organization policy above it stays above it.

`.nightshift/shift-defaults.json` sits outside this order on purpose. It remembers the choices a
composition step would otherwise ask for again — execution mode, hours, tooling policy,
verification profile — and is never itself the source of an effective value. Those four now live
in the `shift` block below. To move a workspace that still has the older file:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/shift-policy.sh" --project "$PWD" migrate --dry-run
```

The dry run prints what it would write and touches nothing; drop `--dry-run` to do it. It keeps a
`.bak` of what it read, refuses while a shift is armed, and does nothing the second time. If a
value you set in the rules file disagrees with one the older file remembers, it names both and
changes neither — delete whichever you do not want and run it again.

Some rows are not negotiable by an allowance at all. Protected paths, never-commit patterns, the
expected commit identity, and `forbiddenCommands` come from the rules file alone; a one-shift
elevation allowance authorizes its own category and nothing else. Allowing `containers` does not
lift a `git .*push` you put in `forbiddenCommands` — the two are separate rules, and a command
blocked by either is blocked.

To see the values in force, with where each one came from:

```bash
"$NIGHTSHIFT_PLUGIN_ROOT/runtime/shift-policy.sh" --project "$PWD" resolve --table
```

Each row ends in its origin — `built-in`, `rules`, or `one-shift` — so a surprising value names
the file to edit. Native Windows uses `runtime\windows\shift-policy.ps1` with `-Project`.

An edit to the rules file applies from the next tool call; the hooks read it every time. The shift
snapshot is frozen for the night, so a change of mind mid-shift means stopping the shift and
starting again with the new setting.

## Editor schema

Editors that honor JSON Schema (VS Code, Cursor, JetBrains) catch invalid names, types, and
values in `.nightshift/rules.json` before a shift. The shipped template sets `$schema` to the
schema file in this repository. If your copy has no `$schema` line, point the editor at
[`nightshift-rules.schema.json`](../plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json)
with a workspace setting — it does not change runtime behaviour:

```json
{
  "json.schemas": [
    {
      "fileMatch": ["**/.nightshift/rules.json"],
      "url": "https://raw.githubusercontent.com/orwa-mahmoud/nightshift/main/plugins/nightshift/skills/nightshift/references/nightshift-rules.schema.json"
    }
  ]
}
```

## Elevation

`elevation` is the one guard that ships switched on. Five categories are denied out of the box, and
each carries the `grep -E` pattern the hardhat and the permission preflight both match against, so
the guard and the preflight can never disagree about what a command needs:

| Category | What it covers |
| --- | --- |
| `sudo` | `sudo` and `doas`, including a path prefix and one layer of quoting |
| `containers` | The Docker socket, `DOCKER_HOST=`, and the create-state verbs: `run`, `create`, `start`, `build`, `compose up` |
| `global-packages` | System and global installs — `brew`, `apt`, `dnf`, `winget`, `npm i -g`, `pip install`, `cargo install`, `go install` |
| `daemons` | `systemctl`, `launchctl`, `service`, `brew services`, `pg_ctl`, and the database servers |
| `external-services` | Interactive logins: `gh auth login`, `npm login`, `docker login`, `az login`, `gcloud auth`, `aws configure` |

**Elevation gates creating system state, never using what already exists.** Connecting to a running
database, calling a local API, and running migrations or tests against your dev stack are not
gated. `docker ps`, `docker logs`, and `brew list` are reads, not elevation; `docker run` is
elevation.

Set a category's `policy` to `allow` to lift it permanently, or let a composition step record a
one-shift allowance with its provenance on the shift policy. An allowance authorizes its category
and nothing else: protected paths, never-commit patterns, and the expected commit identity are
never lifted with it. A missing `elevation` object, or a missing category inside it, denies that
category and keeps the shipped pattern.

```json
{
  "elevation": {
    "containers": { "policy": "allow" }
  }
}
```

`forbiddenCommands` remains your own free-form denylist; it is not how these five are denied.

**Hardhat is hardening, not a sandbox.** The patterns match command text. They stop accidental
drift by a cooperative agent; they are not unbypassable isolation, and they are not a substitute
for the permissions your host enforces.

## Tool rules

`toolDeny` uses the exact, case-sensitive `tool_name` reported by each host. A non-empty value
denies that tool and becomes the model-facing reason; an empty value explicitly allows it. An
unlisted optional tool is allowed. “Allows” here lifts this map entry; command, commit, protected
directory, and rules-file guards still apply independently.

The generated file always carries three native question names:

```json
{
  "toolDeny": {
    "AskUserQuestion": "Park the question with a sensible default and continue.",
    "request_user_input": "Park the question with a sensible default and continue.",
    "AskQuestion": "Park the question with a sensible default and continue."
  }
}
```

`AskUserQuestion` controls Claude Code; `request_user_input` controls Codex; `AskQuestion`
controls Cursor. They are separate on purpose, so each may have different wording. Keep all three
keys present: delete one and that host's question tool reports an invalid configuration instead of
applying an invisible default. Set its value to `""` to allow the question tool.

Cursor's shell tool reports as `Shell` (not `Bash`). Add a `toolDeny.Shell` entry when you want the
same command-map denial on Cursor; the shared command-pattern guards (`forbiddenCommands` and
friends) already treat `Shell` like `Bash`.

The installed host loads its own hook manifest, so the runtime knows which native name arrived.
Setup does not generate or persist a host-specific rules file; keeping all three entries makes one
workspace portable between Claude Code, Codex, and Cursor.

Workspaces created before `request_user_input` or `AskQuestion` was added are missing that host's
key. After upgrading, re-run setup and accept the offered key; Setup adds nothing without
confirmation.

Allowing the tool removes the mechanical denial. The scaffolded punch-list contract,
`clockOutMessage`, and `freshRevivalPrompt` still say “park, don't ask”; owners who want an
interactive shift must change those instructions before arming it too.

Any other observable tool can use the same map:

```json
{
  "toolDeny": {
    "AskUserQuestion": "",
    "request_user_input": "Park the question and continue.",
    "AskQuestion": "Park the question and continue.",
    "Bash": "Shell commands are disabled for this shift.",
    "mcp__github__delete_file": "Repository deletion is disabled for this shift."
  }
}
```

Codex reports file edits as `apply_patch`; `Edit` and `Write` are matcher aliases, not the
canonical input name. Use `"apply_patch"` when configuring Codex file-edit policy.

The hook manifests use the documented catch-all matcher. Claude Code sends built-in and MCP
`PreToolUse` calls except host-defined exclusions such as `EndConversation`; see the
[Claude Code hook matcher reference](https://code.claude.com/docs/en/hooks#matcher-patterns).
Codex sends shell, file-edit, MCP, and other local function tools, but hosted tools such as its web
search do not enter the hook path; see
[Codex tool coverage](https://developers.openai.com/codex/hooks#tool-coverage).

JSON does not support comments. The file's `$schema` supplies editor descriptions and examples;
this section is the raw-file reference. POSIX hooks read `toolDeny` from `rules.json` with the
shipped reader; native Windows hooks use PowerShell's built-in JSON parser. Matching stays exact,
and an unreadable or unsupported file fails closed and does not arm. The bound shift session also
cannot use any observable tool to inspect or change `rules.json`; edit it from the owner session
and the next shift tool call reads the change.

| Env var | Effect |
|---|---|
| `NIGHTSHIFT_TOOL_RULES` | Session override for the exact-name JSON map above (rules file: `toolDeny`). Include both question keys when replacing the map |
| `NIGHTSHIFT_REVIVAL_PROMPT` | your wording for the order a **resumed** conversation gets — default is one line ("you were cut off, continue"), because the thread carries its own context (rules file: `revivalPrompt`) |
| `NIGHTSHIFT_FRESH_PROMPT` | your wording for the **fresh-session** fallback's order — the only rung that starts with no context, so its default points at the punch list (rules file: `freshRevivalPrompt`) |
| `NIGHTSHIFT_GATE_MESSAGE` | your wording for the clock-out gate's DO-NOT-STOP reinjection (rules file: `clockOutMessage`) |
| `NIGHTSHIFT_STALL_WARN` | hold-mode stall warning cadence — warn every N stuck stop attempts (rules file: `stallWarnEvery`; default 3) |
| `NIGHTSHIFT_FORBIDDEN_COMMANDS` | (rules file: `forbiddenCommands`) deny any matching command during a shift — POSIX uses `grep -E` against Bash; native Windows uses .NET regular expressions against the host command string. `git .*push` keeps pushing yours for the night (the `.*` also catches `git -c k=v push`); `rm -rf\|docker\|terraform` fences the rest. An invalid pattern fails closed and names this env var; fix it in session settings. The rules file is guarded during a shift, so only you set or lift a rule — never the agent working the night |
| `NIGHTSHIFT_EXPECTED_EMAIL` | (rules file: `expectedEmail`) during a shift, deny commits whose repository `git config user.email` is not this identity — POSIX and native Windows both read that config. A command-line override (`-c user.email=`, `--author`, `GIT_AUTHOR_EMAIL`) is denied because the guard cannot verify it |
| `NIGHTSHIFT_PROTECTED_DIRS` | (rules file: `protectedDirs`) during a shift, space/pipe-separated dir names never to `git add/commit/tag/remote`. Matching uses the paths Git would write, with `/`; native Windows also normalizes `\` in those Git paths before comparing |
| `NIGHTSHIFT_NEVER_COMMIT_PATTERNS` | (rules file: `neverCommitPatterns`) during a shift, deny a commit whose diff matches this pattern — POSIX `grep -E`; native Windows .NET regular expressions, case-insensitive like POSIX `grep -qiE`. The index is widened to the working tree when the command stages implicitly (`git commit -a`). An invalid pattern fails closed and names this env var; fix it in session settings |
| `NIGHTSHIFT_WATCH` | minutes between night-watchman wakes; `0` disarms it. Unset, the interval is the rules file's `watchMinutes` — shipped as **10** — and an unreadable rules file refuses to arm the watchman rather than guessing. The revival resumes **the shift's own conversation by id** (`claude --resume <recorded session> -p`) — the same recorded conversation id in terminal and IDE history. Before each spawn the watchman advances a process lease, so the recovered process owns observable shift tools and older generations are fenced. An IDE panel already open on that thread cannot auto-refresh while the headless revival appends to it; [reopen the thread instead](how-it-works.md#reopening-a-revived-thread). The watchman degrades per attempt to `claude --continue -p` and last to a fresh `claude -p` in case the conversation itself is what broke. On a codex-owned shift the codex watchman revives with `codex exec resume <recorded session>` and falls back to a fresh `codex exec`. Cursor keeps two conversation stores: the IDE Agent tab records a `conversation_id` under `~/.cursor/projects/.../agent-transcripts`, and `agent --resume` talks only to the CLI store under `~/.cursor/chats`. Never pass the IDE id to `agent --resume` — that is a different chat. The Cursor watchman mints a CLI worker on the first IDE death, records it in `.shift-worker`, and `--resume`s that same id on later wakes. The origin IDE tab is pointed at `agent --resume="<cli_id>" --workspace "<abs>"` |
| `NIGHTSHIFT_WATCH_AGENT` | session override for the rules file's `watchAgent`. Empty (shipped) keeps each host's default resume ladder. A non-empty value is the spawn command used verbatim on every revival attempt — for example `claude -p` forces a fresh Claude session and skips resume/`--continue`. Codex uses the same key for a verbatim `codex exec …` override |
| `NIGHTSHIFT_RECEIPTS_AUTO_COMMIT` | session override for `receiptsAutoCommit`. Shipped **false**: even when Setup created a local receipts git under `.nightshift/`, clock-out and Archive do not commit it — the owner does. Set `true` only if you want the headless `nightshift@localhost` snapshot on every shift end / Archive |
| `NIGHTSHIFT_STALL_MAX` | (rules file: `stallMax`) by default a stuck agent is held and red-flagged in the shift log, never clocked out; set `=N` to clock the shift out after N stuck attempts. |
| `NIGHTSHIFT_NOTIFY_CMD` | (rules file: `notifyCommand`) shift-end ping; runs as unrestricted owner-provided shell with `$NIGHTSHIFT_SUMMARY` set. POSIX uses `sh -c` (e.g. `say "$NIGHTSHIFT_SUMMARY"`); native Windows uses PowerShell `Invoke-Expression` (e.g. `Write-Host $env:NIGHTSHIFT_SUMMARY`). It can access the network if your command does. The watchman rings it too — once per outage — when a dead session could not be revived: the one night event that needs you. A successful Claude revival never pages; after the headless subprocess exits, it lands as a notice in `parking-lot.md`, with the thread's resume command and deep links when a session id was recorded. Successful Codex revivals log to `shift-log.md` only |

**Recovery display.** The watchman does not require an owner to monitor it. Reopening a revived
thread is currently only how the owner refreshes a stale panel before inspecting or interacting;
the linked upstream refresh work would make that handoff smoother, not enable recovery itself.

**Local profiles.** `runtime/apply-profile.sh` (native Windows: `runtime/windows/apply-profile.ps1`)
can preview or copy every version-1 or version-2 JSON file in
`plugins/nightshift/skills/nightshift/references/profiles/`; the shipped `balanced`, `fast`, and
`strict` profiles are version 2 and also carry shift defaults and a Gates block. That is a
one-time local write, not a policy subscription. Fill keeps every owner value and refuses a file
missing either native question policy. Replace starts from the complete shipped template, applies
the profile, and shows the full next file first. Apply only while unarmed. Native Windows uses
PowerShell's JSON parser; it does not require `jq`.

**Two cadences have no env override.** `watchRetrySeconds` is the space-separated pause list
between revival attempts in one wake (shipped `"30 120"`), and `longUnitWarnMinutes` is `0` by
default — set it positive to have the shift log warn that a live unit has run that many minutes
with no durable checkpoint. It never resets or replaces the stall counter. Edit both in
`rules.json` between shifts.

**Retention** lives in the same rules file under `retention`, and is not shift-scoped: it is
read only by Nightshift Archive. Both `runtimeLogDays` and `archiveDays` default to `0`
(keep forever). A positive integer is an opt-in age in days. Archive prints the exact
eligible paths first; deletion needs an explicit yes and never runs from a hook, start,
status, Doctor, or recovery.

## Shift, handoff and archive

Three blocks group the settings that are not guards. They are all optional, and an absent key keeps
the default in the table.

`shift` holds the choices a composition step would otherwise ask for every time.

| Key | Default | Values |
|---|---|---|
| `verificationProfile` | `fast` | `fast` never runs the punch list's `## Gates`, `balanced` runs them once before clock-out, `strict` before every tick and once at the end, `custom` is the cadence the punch list itself names |
| `hours` | `null` | A whole number of hours for a composed shift, or `null` to be asked. A finite punch list can still end at its last tick with no clock |
| `execution` | `review-first` | `review-first` shows the composed shift before it runs; `run-direct` starts it. Neither widens what the shift may do |
| `toolingPolicy` | `existing-tools` | `existing-tools`, `review-missing`, or `auto-add`. Artifact mode is always `existing-tools` |

A new workspace verifies nothing, because the gates a new owner has not written yet should not fail
a shift. Set a profile once you have commands worth running.

`handoff` is the morning receipt — presentation only. It never decides whether a check ran, and it
cannot turn an unavailable check into a passed one.

| Key | Default | Values |
|---|---|---|
| `enabled` | `true` | `false` writes no page and leaves the ledger, the archive and the shift log exactly as they are |
| `view` | `owner` | `owner`, `reviewer`, `release`, `artifact` |
| `language` | `auto` | Follows the language of the conversation that ran the shift. Paths, commands and identifiers are never translated |
| `detail` | `concise` | `concise` or `detailed` |
| `sections` | `[]` | Any of `shift`, `baseline`, `changed`, `parked`, `unsupported`, `next`, in the order you want them. Empty means the built-in order for the view |
| `templatePath` | `""` | A Markdown template, relative to the workspace. It carries wording, never policy |

`report` is the shift report — one page the night writes as it goes, a section per punch-list
item, saying what was delivered and why. It never reaches a public commit message.

| Key | Default | Values |
|---|---|---|
| `enabled` | `true` | `false` writes no report. Punch status, real outputs, continuity and your selected verification are all still kept, and no per-item receipt comes back in its place |
| `progressMode` | `time` | `completion-only` writes a section once, at the end. `time` updates it after `progressMinutes` of work on that item, `tokens` after `progressTokens`, `either` at whichever comes first |
| `progressMinutes` | `20` | Minutes of work on the current item before an update is due. Checked when a tool returns, so it never interrupts a running command |
| `progressTokens` | `100000` | Tokens of work before an update is due. A starting value to tune, not a host limit |
| `usage` | `when-available` | Record what each item cost, from the numbers your host already exposes. `off` records none. Input, output and cached input are reported separately by name; a dimension the host does not report reads `unavailable`, never zero |
| `legacyItemReceipts` | `false` | Artifact items are completed by their report section. `true` also writes the older per-item receipt file. Baseline, checkpoint and source receipts are unaffected |
| `templatePath` | `""` | A Markdown template for the report, on the same terms as the handoff template: wording only |

Per-item accounting is Nightshift's own work, not something a host has to support: it records a
baseline when an item starts, tracks while the item is active, calculates the item's consumption
when it finishes, and resets so the next item starts from its own baseline. Where a host exposes
cumulative counters that is a delta; where it emits usage events instead, they are summed for the
active item. The shift total adds the shared overhead that belongs to no single item and says
whether the coverage is complete or partial. No token count is ever turned into a price.

[`examples/shift-report.md`](../examples/shift-report.md) shows the shape, including an item still
in progress and usage that is only partly available.

`recovery` decides what a session the watchman revives is allowed to do. It never widens what your
host permits, and it never lifts a rule in this file.

| Key | Default | Values |
|---|---|---|
| `launchScope` | `inherit-recorded-scope` | Revive with the permissions the shift was started under, as recorded when it armed. `host-grant` starts a revived session with the documented grant for that host — on Codex `danger-full-access`, on Cursor `--trust --yolo`. `host-default` passes no permission argument at all |

**A revival never gets more than the session it is replacing had.** The shipped choice reads what
the shift recorded about itself when it armed and asks for exactly that. Where the host reported no
scope — or the shift predates the recording — it falls back to the host's own default and says so
in `shift-log.md`, rather than reaching for the broader grant. That is narrower than Nightshift
used to be: a revived Codex session under `workspace-write` can edit but not commit, and it will
report that honestly instead of widening to make a commit possible.

`host-grant` is how you say you want the broad grant anyway, and it happens only because you wrote
it here — a workspace that predates this setting has not chosen it. Whichever scope is in force is
named on every revival, and a failed revival is retried at the same one, never a broader one.
Claude Code inherits its own launch in every case. `watchAgent` remains the advanced override for
the whole command.

`archive` decides where finished shift state is filed. Filing is a copy: `retention` above is the
only setting that removes anything, and only Nightshift Archive prunes, after showing you the exact
paths and asking.

| Key | Default | Values |
|---|---|---|
| `automatic` | `false` | `true` files the shift when it ends. It never implies pruning |
| `root` | `archive` | Directory for dated archives, relative to `.nightshift/`. The name is yours; where it sits is not — an absolute path, a path containing `..`, or a symlink is refused rather than followed, and Archive says so. Writing outside the state area is an unsupported request, not a setting |
| `layout` | `date` | `date` groups a night under `YYYY-MM-DD`; `shift` gives each shift its own directory. The shift id names the files either way, so two shifts in a day never collide |

Changing `root` never moves or hides what is already filed: an older history under the previous
root stays exactly where it is, and stays readable. Filing copies the receipts and leaves the live
ones in place, so a shift still in progress keeps the receipts its own progress checks read.
| `templatePath` | `""` | A Markdown template for the archive summary |

Every rule above is **shift-scoped**: it applies to the bound session while `.shift-armed` exists,
`.nightshift/punch-list.md` has an open `- [ ]`, and the gate has not ended the shift. With no
armed shift, or once the last box is ticked, your session is ordinary again and none of them are
watching. They are site rules for the night, not a background scanner.

The two commit knobs read git, so they work against the repository the commit lands in — one the
command names itself (`git -C <dir>`, `cd <dir> &&`), else the tool's working directory, the
project dir, or the single repo below it. Where that is genuinely ambiguous, such as a workspace
holding two repos with the commit run from the root, they deny and say so rather than guess.

**Changed in v0.4.0:** the commit guards resolve the repository they inspect, so they hold in the
recommended layout below as well as in-place. Commits there count as shift progress too.

**Changed in v0.3.0:** by default a stalled agent is now held and red-flagged, never clocked out —
in the clock-out gate. Set `NIGHTSHIFT_STALL_MAX=N` to restore
auto-clock-out after N stuck attempts.
