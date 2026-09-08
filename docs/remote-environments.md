# Remote SSH and devcontainers

Nightshift supports remote environments when the runtime is co-located. The host process, plugin,
hooks, repository, `.nightshift/` workspace, transcripts or rollouts, and watchman must all see the
same operating-system process table and filesystem namespace. The editor UI may be somewhere else.

That boundary is the feature. Nightshift does not add remote orchestration, copy live state between
machines, or infer that a process on one side of a connection is the process recorded on the other.

## Support matrix

| Layout | Status | Required placement | Recovery boundary |
|---|---|---|---|
| Local macOS or Linux | Supported | Host, plugin, repository, state, and watchman are local | Existing macOS and Linux CI |
| Native Windows | Runtime fixture verified (x86_64) | Host, plugin, repository, state, and watchman are in native Windows | See [Native Windows](windows.md#native-windows). CI covers the bundled PowerShell path with local host fixtures; an authenticated Claude Code or Codex process on Windows remains an attended check |
| WSL | Supported as Linux | Everything is inside one WSL distribution | No split Windows/WSL process or path state |
| Remote SSH to Linux | Runtime fixture verified (x86_64) | Hook scripts, plugin, repository, state, and watchman are on the SSH target; the authenticated host remains an attended check | The fixture proves a detached watchman across separate SSH connections; account logout policy remains administrator-owned |
| Linux devcontainer | Runtime fixture verified (x86_64) | Hook scripts, plugin, repository, state, and watchman are in the same container; the authenticated host remains an attended check | The fixture proves a detached watchman across separate container exec connections; stopping or rebuilding the container stops it |
| Remote SSH to native Windows | Not verified | — | Use native Windows locally until a verified SSH fixture covers the Windows process and session model |
| Host outside, tools or files inside a container | Unsupported | — | The watchman cannot prove host liveness across the PID namespace |
| State or work target across host/container or local/remote namespaces | Unsupported | — | Absolute links, locks, process IDs, and start times no longer name the same resources |
| Network filesystem without local atomic rename and private-file semantics | Unsupported | — | Lease ownership and capability privacy cannot be guaranteed |

## Remote SSH

Run the host and install the plugin on the remote target. Open the repository through the remote
session, scaffold `.nightshift/` there, and start the shift there. A local editor window may display
the remote session, but a locally running host process with a remote shell is a split runtime and is
not supported.

The watchman is launched with `nohup` on the target. Losing the SSH transport can kill the
interactive host and leave the detached watchman in place; the watchman then applies the normal
process-evidence ladder before recovery. This depends on the target's login policy. Machines that
reap all user processes at logout, suspend, reboot, or disappear cannot provide unattended
recovery without a target-local scheduler or service policy.

Install schedules on the remote target, not the client. They use the target's clock, account,
filesystem, credentials, and process namespace.

Before leaving a remote shift unattended, verify:

1. `pwd`, the repository, and `.nightshift/` are remote paths.
2. The host command and plugin are installed and authenticated on the target.
3. `.shift-session` records a target process and a target transcript or rollout.
4. `.watchman` names a process whose current directory is the authoritative workspace.
5. The remote account permits that process to survive an SSH disconnect.
6. The target will remain awake and connected for the shift.

## Devcontainers

Install and run the host and plugin inside the devcontainer. Keep the repository and
`.nightshift/` on a bind mount or named volume that survives container replacement. A
`.nightshift-link` may connect paths only inside the container's namespace.

Ending an exec connection does not end recovery while the container and its user processes remain
alive. An editor disconnect has the same process boundary but remains an attended owner check rather
than a CI claim. Stopping, rebuilding, or deleting the container kills both the host and watchman. A
scheduler inside a stopped container cannot restart it; container lifecycle belongs to the owner or
the platform outside Nightshift.

Do not run the host on the container host while forwarding individual tool commands into the
container. PIDs, process start times, current directories, transcripts, and lease files would cross
different trust boundaries, so recovery must stand down rather than guess.

## Reproducible evidence

The compatibility probe exercises a live Linux process and filesystem boundary with synthetic host
events, then emits a sanitized JSON receipt. It checks:

- workspace and work-target resolution through an explicit task-root link;
- Claude Code and Codex hook-script execution against the authoritative state;
- PID plus process-start-time identity;
- private-file mode and same-filesystem rename replacement;
- watchman PID placement, workspace current directory, STOP handling, and cleanup.

The Remote SSH harness additionally closes the connection that launched a detached watchman,
reconnects, and proves the same remote process is still alive before issuing STOP.
The devcontainer harness does the equivalent across separate `devcontainer exec` connections.

Remote SSH:

```bash
ssh target 'cd /absolute/nightshift-repository &&
  tests/environments/probe.sh remote-ssh "$PWD"'
```

Devcontainer fixture:

```bash
npx --yes @devcontainers/cli@0.88.0 up \
  --workspace-folder . \
  --config tests/environments/devcontainer/devcontainer.json
npx --yes @devcontainers/cli@0.88.0 exec \
  --workspace-folder . \
  --config tests/environments/devcontainer/devcontainer.json \
  bash tests/environments/probe.sh devcontainer /workspaces/nightshift
```

CI crosses an actual OpenSSH connection for the first probe and starts the checked-in devcontainer
for the second. The committed receipts are scoped to the Linux x86_64 runners that produced them;
the probe records architecture so another architecture cannot be presented as the same evidence.
Each generated receipt is compared byte-for-byte with
`tests/environments/receipts/remote-ssh-linux.json` or
`tests/environments/receipts/devcontainer-linux.json`, then uploaded with the run. The receipts
contain no usernames, hostnames, paths, process IDs, credentials, or timestamps.

The fixtures use local stub identities and never require a hosted account or subscription. They
verify Nightshift's paths, hook scripts, process evidence, lease storage, and watchman placement;
they do not pretend to verify plugin loading by an authenticated host, third-party authentication,
editor UI synchronization, abrupt transport failure, or the target administrator's logout and
container-lifecycle policy.

---

[Check your first attended run](first-night-checklist.md#first-night-safety-checklist) · [Documentation index](README.md#documentation)
