# Agent contribution guide

AI-assisted contributions are welcome. The same correctness, security, licensing,
testing, and quality standards apply regardless of which tools are used.

- Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before changing the repository.
- Use the [contribution map](docs/contribution-map.md) to choose an area, likely files, and focused
  checks.
- Work from an open issue for anything beyond a typo or small fix.
- Keep Nightshift inside the native Claude Code, Codex, and Cursor plugin, skill, and hook
  ecosystems; do not introduce another runtime or installation channel.
- Keep each pull request focused on one concern.
- Run the checks required by `CONTRIBUTING.md` and report their exact results.
- Never claim that a check passed unless it was actually run successfully.
- Treat generated work as untrusted until it has been reviewed for correctness,
  security, licensing, and repository fit.

## How Nightshift is built

- **The model decides; the runtime does only what a model cannot.** Mechanics are for what the
  model cannot see or do for itself: keeping a process alive and reviving it, holding a deadline,
  honouring STOP, surviving a crash, keeping files safe from two writers, and keeping a session
  working while a box is still open. Planning, judging when work is done, resolving conflicts and
  choosing what to share belong to the model, guided by clear instructions in the skills. Before
  adding a check, validator, state machine or setting, ask whether an instruction would do. Add the
  mechanism only when the model cannot handle the case, and say why in the pull request.
- **Instruct, don't police.** When the model needs steering, such as an open item when it tries to
  stop or a receipt that is due, a hook gives it a short instruction at that moment. Hooks do not
  verify its work or second-guess its judgement.
- **One source of truth.** Every fact lives in one place and is read from there. Never add a
  setting that repeats what a file the owner already edits says (Git's ignore rules, the punch-list
  contract, a template), and never keep the same value, message or rule in two files.
- **The owner can change everything.** Rules, templates, contracts, gates and every shipped default
  belong to the owner, who may edit or replace any of them with their own. Ship commented defaults
  the owner edits, not settings that generate them. A guard restricts only what the owner turned
  on, or what protects the shift's own records.
- **Nothing is published by default.** Nightshift commits locally. It pushes, opens a pull request
  or posts only when the owner's punch list says so.
