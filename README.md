# mac-sync

Keep two Macs in sync without turning your setup into a chore.

`mac-sync` lets a laptop **pull** its configuration from another Mac over SSH and apply it idempotently with Ansible. Change a setting on your Mac mini, and your MacBook Air picks it up the next time it can reach the mini. Grab the laptop, leave the house, and everything is where you left it.

> **Status:** design phase. This README describes the intended behaviour; see [Roadmap](#roadmap) for what exists.

## Why not Infrastructure as Code?

IaC tools (Nix, Ansible playbooks as the source of truth, Chef, etc.) work best when you manage *many* machines from a *declared* desired state. That discipline is also their weakness for a personal setup:

- Every change has to be made **in code first**. When you're in a hurry you tweak a setting by hand "just this once", and now the repo and the machine have drifted apart.
- Once the repo stops being trustworthy, it stops being used.
- For two machines, the overhead of declaring everything rarely pays off.

`mac-sync` flips this around: **a real, living Mac is the source of truth.** You configure your primary machine the way you normally would: System Settings, `brew install`, editing dotfiles. The tool *observes* it and replicates the state to the other Mac. No ritual, no drift, because there is nothing to forget to update.

Ansible is still used, but as an **idempotent apply engine**, not as the place you author your config.

If you manage a fleet of Macs, use proper IaC. This project is for people with a few personal machines who want them to feel like one.

## How it works

```
 ┌──────────────┐   1. SSH: capture state    ┌───────────────┐
 │  MacBook Air │ ─────────────────────────▶ │   Mac mini    │
 │   (target)   │ ◀───────────────────────── │   (source)    │
 │              │   2. pull snapshot         │ source of truth│
 │  3. apply    │                            └───────────────┘
 │  (Ansible)   │
 └──────────────┘
      ▲
      │ launchd runs the launcher on a timer
```

1. **Capture**: over SSH, the target runs read-only commands on the source to snapshot its state (Homebrew bundle, `defaults` domains, dotfiles, editor extensions, ...).
2. **Pull**: the snapshot is copied to the target (rsync/Ansible `fetch`).
3. **Apply**: Ansible applies the snapshot locally using idempotent modules. Re-running with no changes does nothing.

The source never needs to know about the target, and it never pushes. It only needs Remote Login (SSH) enabled and a key-restricted account.

### The launcher

A small shell script, scheduled by a **launchd** agent, ties it together. On each tick it:

1. Takes a lock, so runs never overlap.
2. Checks whether the source is reachable (short SSH timeout, `BatchMode`). If not, it exits quietly. You're on a train, nothing to do.
3. Runs the Ansible playbook.
4. Logs the result and optionally sends a macOS notification on failure.

Because it simply no-ops when the mini is unreachable, it is safe to run every 15-30 minutes. Pair it with Tailscale or a similar VPN if you want sync to work away from home.

## What gets synced

The goal is *as much as is useful, without bloating the system*. Each category is a separate, opt-in Ansible role.

| Category | Mechanism | Default |
|---|---|---|
| Homebrew formulae, casks, taps | `brew bundle dump` → `brew bundle` | on |
| Mac App Store apps | `mas` | opt-in |
| Dotfiles (`.zshrc`, `.gitconfig`, ...) | allow-listed files, rsync | on |
| macOS preferences (Dock, Finder, keyboard, trackpad) | `defaults` / `osx_defaults` for an allow-list of keys | on |
| VS Code / editor settings & extensions | settings file + extension list | on |
| SSH keys and `~/.ssh/config` | copied over SSH, additive only, never committed | on |
| Shell tooling (oh-my-zsh, asdf/mise versions) | version manifests | opt-in |
| Terminal profiles (iTerm2/Ghostty) | config file | opt-in |

### What is deliberately *not* synced

- **Other secrets**: Keychain items, API tokens, `.env` files. (SSH keys and config *are* synced; see [SSH keys and secrets](#ssh-keys-and-secrets).)
- **Machine-specific state**: hostname, network settings, display layout, battery/power settings.
- **App data and caches**: documents belong in iCloud, git, or a backup tool.
- **Whole-`~/Library` copies**: these bloat the system and break across macOS versions.

Syncing uses **allow-lists, not deny-lists**. Nothing moves unless it is named in the config.

## Requirements

- Two Macs on macOS 13+
- On the source: *System Settings → General → Sharing → Remote Login* enabled
- On the target: Homebrew, Python 3, Ansible (`brew install ansible`)
- SSH key auth from the target to the source (no passwords; the launcher runs unattended)

## Quick start

> Commands below are the intended interface and may change as the tool takes shape.

```bash
# On the target (MacBook)
git clone https://github.com/<you>/mac-sync.git ~/git/mac-sync
cd ~/git/mac-sync

cp config.example.yml config.yml     # set source host, user, enabled roles
./bin/mac-sync doctor                # check SSH, Ansible, permissions
./bin/mac-sync pull --check          # dry run, shows what would change
./bin/mac-sync pull                  # apply for real
./bin/mac-sync install-agent         # install the launchd timer
```

## Configuration

`config.yml` (git-ignored) holds per-user settings:

```yaml
source:
  host: mac-mini.local        # or a Tailscale name
  user: vadim
  ssh_key: ~/.ssh/mac_sync_ed25519
interval_minutes: 30
roles:
  homebrew: true
  dotfiles: true
  macos_defaults: true
  vscode: true
  mas: false
dotfiles:
  - .zshrc
  - .gitconfig
  - .config/starship.toml
```

## SSH keys and secrets

You use the same SSH keys at home and on the go, so `mac-sync` copies them from the source to the target. The rules:

- **Never committed.** Keys travel only over the encrypted SSH connection between your two Macs, are staged in a private temp directory (`0700`) and removed afterwards. They never touch the repo, logs, or `config.yml`. `.gitignore` blocks common key and config patterns as a second line of defence.
- **Additive only.** Keys that exist on the target but not on the source are **left alone**, so keys you add on the MacBook survive. A key is only written when it is missing, or when it differs (see conflicts below).
- **Correct permissions.** Private keys are `0600`, `~/.ssh` is `0700`, applied on every run.
- `~/.ssh/config` and `known_hosts` are merged the same way, entry by entry rather than as whole-file replacement.

Keychain items, API tokens and `.env` files are still not synced.

## Conflicts

When the source and target disagree about something the target already has (a different `.zshrc`, a key with the same name but different content, a changed `defaults` value), `mac-sync` **does not silently pick a winner.**

- Run interactively (`mac-sync pull`), it shows a diff and asks: keep target, take source, or skip.
- Run by the launchd timer there is nobody to ask, so it applies everything that is conflict-free, **records the conflicts as pending**, and sends a notification. Nothing in conflict is touched.
- `mac-sync resolve` walks through pending conflicts later and remembers your choices where you ask it to.

## Safety

- `--check` mode shows a diff before anything is applied.
- Files that would be overwritten are backed up first.
- Nothing is ever deleted from the target unless a role explicitly opts in (for example, `brew bundle cleanup` is off by default).
- The source is only ever read from.

## Helper tools

Ansible does the applying, but where a small tool makes a role simpler (merging `ssh_config` entries, diffing `defaults`, resolving conflicts), it is a small **Python** script, called from the role as a custom module or helper. Python is preferred over compiled languages because scripts can be read and audited as-is, without decompiling a binary, which matters for a tool that handles your SSH keys. Other languages are fine when they are clearly the better fit, but they stay small and readable.

## Directions and conflicts

v1 is **one-way: source → target.** If you change something on the MacBook it will be overwritten on the next sync, so make changes on the mini. Two-way sync needs conflict resolution and is a possible future direction, not a promise.

## Project layout (planned)

```
bin/mac-sync            launcher / CLI
launchd/                LaunchAgent plist template
ansible/
  playbook.yml
  roles/                one role per category
tools/                small Python helpers used by roles
config.example.yml
CLAUDE.md               instructions for AI coding agents
```

## Roadmap

- [ ] Launcher script with lock, reachability check, logging
- [ ] launchd agent install/uninstall
- [ ] Roles: Homebrew, dotfiles, macOS defaults, VS Code
- [ ] `doctor` and `--check` dry-run support
- [ ] Optional roles: mas, terminal profiles, version managers
- [ ] SSH keys/config role (additive, never committed)
- [ ] Conflict detection, interactive prompts, `resolve` command
- [ ] Notifications on failure or pending conflicts
- [ ] Docs for Tailscale / away-from-home setups

## Contributing

Issues and PRs welcome, especially new roles and macOS-version fixes. Read [CLAUDE.md](CLAUDE.md) for the design rules every change should follow, such as idempotency, allow-lists, and no secrets.

## License

TBD
