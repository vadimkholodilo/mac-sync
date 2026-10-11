# CLAUDE.md

Guidance for AI coding agents working on `mac-sync`. See [README.md](README.md) for the user-facing overview.

## What this project is

A tool that keeps two Macs in sync. The **target** Mac (MacBook) SSHes into the **source** Mac (Mac mini), pulls a snapshot of its configuration, and applies it locally with Ansible. A small launcher, scheduled by launchd, does this periodically whenever the source is reachable.

## Core design principles (do not violate)

1. **The live source Mac is the source of truth**, not the repo. This is the whole reason the project isn't classic IaC. Never require the user to declare their config in code before it takes effect.
2. **Pull, never push.** The target initiates everything. The source is only ever read from.
3. **Idempotent.** Running the playbook twice in a row must report zero changes the second time. Prefer real Ansible modules (`community.general.homebrew`, `osx_defaults`, `ansible.builtin.copy`/`synchronize`, `lineinfile`) over `shell`/`command`. If `command` is unavoidable, set `changed_when` and `creates`/`when` correctly.
4. **Allow-lists, not deny-lists.** Nothing is synced unless explicitly named in config or a role's defaults.
5. **Secrets are copied, never committed or logged.** SSH keys and `~/.ssh/config` are intentionally synced (the user needs the same keys at home and on the go), but only over the SSH channel, staged in a `0700` temp dir and cleaned up. Never write key material to the repo, logs, fixtures, test output, or `config.yml`. Never commit `config.yml`. Keep `.gitignore` blocking key/config patterns. Keychain items, tokens and `.env` files are not synced at all.
6. **Additive, never destructive.** Never remove or overwrite target-only items (e.g. SSH keys the user added on the target). Merge `ssh_config`/`known_hosts` entry by entry. Enforce permissions (`~/.ssh` 0700, private keys 0600) on every run.
7. **Conflicts are the user's call.** If the target already has something that differs from the source, never silently overwrite. Interactive runs show a diff and prompt (keep target / take source / skip). Non-interactive (launchd) runs apply only conflict-free changes, record conflicts as pending, notify, and leave them untouched. `mac-sync resolve` handles pending ones. Detect interactivity (TTY), don't assume.
8. **No bloat.** Don't copy whole directories like `~/Library`. Don't install background daemons beyond the single launchd agent. Sync small, well-understood pieces of state.
9. **Safe by default.** Support `--check`/diff. Back up files before overwriting. Never delete from the target unless a role explicitly opts in (e.g. no `brew bundle cleanup` by default).
10. **Quiet failure when offline.** An unreachable source is the normal case (laptop is away). The launcher must exit 0 silently, not alert or error.

## Tech stack

- **Ansible** for applying state (chosen over Go: native SSH, idempotent modules, far less code).
- **Roles live in this repo; Galaxy is for collections only.** Our roles do capture → stage → apply with conflict prompts and additive-only rules, which generic Galaxy roles can't do, and third-party roles shouldn't sit on the path that handles SSH keys. Take *modules* from Galaxy collections (e.g. `community.general` for `osx_defaults` and `homebrew`) instead of reimplementing them. Pin exact versions in `ansible/requirements.yml`, install into a project-local `collections_path` (set in `ansible.cfg`) so nothing depends on system-wide installs, and have the launcher's first-run bootstrap install them. **Bootstrap:** on first start the launcher installs missing dependencies (Homebrew, Ansible, collections) itself, so the README must not ask users to install them by hand. It always lists what it will install and asks for confirmation; unattended (launchd, no TTY) runs never install anything, they just report what is missing. Don't add Galaxy roles; ask first if one seems worth it.
- **Python helpers** (`tools/`) for logic Ansible does awkwardly: merging `ssh_config`, diffing `defaults`, conflict handling, custom Ansible modules. Python is preferred because it is a script and can be inspected as-is, unlike compiled binaries (Go) that need decompiling. This matters since the tools touch SSH keys. Use the standard library where possible, keep scripts small, and pin any dependency. Another language is acceptable only when clearly better, and must stay small and readable. No committed binaries.
- **POSIX-ish shell (zsh/bash)** for the launcher only. Keep it small. If it grows logic, move the logic into Ansible.
- **launchd** (LaunchAgent in `~/Library/LaunchAgents`) for scheduling, not cron.
- macOS 13+ on Apple Silicon and Intel. Keep Homebrew prefix handling arch-agnostic (`/opt/homebrew` vs `/usr/local`).

## Planned layout

```
bin/mac-sync            CLI / launcher (doctor, pull, install-agent, uninstall-agent)
launchd/                LaunchAgent plist template
ansible/
  ansible.cfg
  requirements.yml      pinned Galaxy collections (no roles)
  playbook.yml
  roles/<category>/     one role per sync category, independently toggleable
tools/                  small Python helpers/modules used by roles
config.example.yml      committed template; real config.yml is git-ignored
```

Update this section when the real layout changes.

## Conventions

- **One role per category** (homebrew, dotfiles, macos_defaults, vscode, ...). Each is enabled via `config.yml` and must work standalone.
- Role flow: *capture from source over SSH → stage in a temp dir → apply to target*. Keep capture read-only.
- Variables are namespaced by role (`homebrew_*`, `dotfiles_*`).
- `macos_defaults` syncs only an allow-listed set of domain/key pairs. Never export entire domains blindly, since they contain machine-specific values.
- Launcher requirements: lock file to prevent overlap, SSH with `BatchMode=yes` and a short `ConnectTimeout`, log to `~/Library/Logs/mac-sync/`, optional notification only on genuine apply failures.
- YAML: 2-space indent, named tasks, `ansible-lint` clean.
- Shell: `set -euo pipefail`, quote everything, `shellcheck` clean.

## Testing and verification

You cannot fully test this without two Macs, so be explicit about what was and wasn't verified.

- Lint: `ansible-lint`, `yamllint`, `shellcheck bin/*`, `ruff` and `pytest` for `tools/`. Test helpers against fake keys generated into a temp dir, never real ones.
- Syntax: `ansible-playbook --syntax-check ansible/playbook.yml`.
- Dry run: `ansible-playbook --check --diff ...` (or `bin/mac-sync pull --check`).
- Idempotency: run the playbook twice; the second run must show `changed=0`.
- To test locally with one machine, point `source.host` at `localhost`.
- Never run apply steps that modify the user's real system settings without being asked. Prefer `--check`.

## Things to ask before doing

- Adding a new synced category that touches sensitive areas (anything near credentials, network, or security settings).
- Introducing a dependency beyond Ansible, Homebrew, and standard macOS tools, including any new Galaxy collection or any Galaxy role.
- Changing sync direction or adding two-way sync (currently out of scope for v1).
- Writing to the user's real `~/Library/LaunchAgents` or shell dotfiles during development.

## Out of scope (for now)

Two-way sync, conflict resolution, managing more than a couple of machines, Linux/Windows, a GUI, syncing app data or documents.

## Docs

Keep README.md accurate. If behaviour or the CLI changes, update the README in the same change. The README marks planned features; mark them done as they land.
