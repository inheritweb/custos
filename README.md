# omarchy-backup

`omarchy-backup` is a shell-first backup and restore companion for Omarchy desktops.
It uses `restic` for encrypted deduplicated backups and `rclone` for remote storage.

The first supported remote adapter is Google Drive.

## Status

This repository is in the first shell milestone. The CLI backup engine is usable,
and the TUI is a shell-rendered dashboard over the same commands.

## Requirements

- `bash`
- `jq`
- `restic`
- `rclone`

On Omarchy, install missing packages with:

```bash
omarchy pkg add jq restic rclone
```

## Install

Install from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/inheritweb/omarchy-backup/main/scripts/install.sh | bash
```

The installer places project files in:

```txt
~/.local/share/omarchy-backup
```

and installs the command wrapper at:

```txt
~/.local/bin/omarchy-backup
```

For a VM test against a branch or commit:

```bash
curl -fsSL https://raw.githubusercontent.com/inheritweb/omarchy-backup/main/scripts/install.sh | bash -s -- --ref <branch-or-sha>
```

The installer uses `omarchy pkg add jq restic rclone` when Omarchy is available.
Outside Omarchy, it falls back to `sudo pacman -S --needed jq restic rclone`.
Use `--no-deps` to skip dependency installation.

## Journeys

### First Backup On This Machine

Install dependencies:

```bash
omarchy pkg add jq restic rclone
```

Check the local environment:

```bash
./bin/omarchy-backup doctor
```

Create or inspect the config:

```bash
./bin/omarchy-backup config show
./bin/omarchy-backup paths list
```

Set up Google Drive and initialize the Restic repository:

```bash
./bin/omarchy-backup setup
```

Preview and run the first backup:

```bash
./bin/omarchy-backup backup --dry-run
./bin/omarchy-backup backup
```

Verify it:

```bash
./bin/omarchy-backup snapshots
./bin/omarchy-backup check
```

### Interactive TUI

Launch the interactive terminal UI:

```bash
./bin/omarchy-backup tui
```

The TUI is a shell frontend over the same commands documented below. It uses a
static dashboard layout: config, snapshots, and actions stay visible while focus
moves between the snapshots and actions panes with Tab.

On first run, the actions pane lets you connect Google Drive, restore an existing
config, or create a new config. Once configured, snapshots stay visible alongside
backup, restore, path, repository, and maintenance actions.

If no stored password command is available, the TUI asks for the repository
password once at session start and reuses it for repository actions. Passwords
are passed through the process environment, not as command-line arguments.

### Restore A File Safely

By default, restore goes to a staging directory so local files are not overwritten:

```bash
./bin/omarchy-backup restore latest ~/Documents/file.pdf
```

The default target is:

```txt
~/Restored/omarchy-backup/latest
```

Restore to the original location only when that is intentional:

```bash
./bin/omarchy-backup restore latest ~/Documents/file.pdf --original
```

### Fresh Omarchy Restore

On a newly installed machine, install dependencies and configure Google Drive:

```bash
omarchy pkg add jq restic rclone
./bin/omarchy-backup remote setup
```

Restore the saved `omarchy-backup` config from the remote:

```bash
./bin/omarchy-backup config restore
```

Then inspect snapshots and restore to a staging directory:

```bash
./bin/omarchy-backup snapshots
./bin/omarchy-backup restore latest --target ~/Restored/omarchy-backup/latest
```

Use `--original` only when you want Restic to write back to the original paths.

### Change What Gets Backed Up

List the active include and exclude rules:

```bash
./bin/omarchy-backup paths list
```

Add or remove protected paths:

```bash
./bin/omarchy-backup paths include add ~/Projects
./bin/omarchy-backup paths include remove ~/Projects
```

Add or remove exclude patterns:

```bash
./bin/omarchy-backup paths exclude add '**/*.qcow2'
./bin/omarchy-backup paths exclude remove '**/*.qcow2'
```

Preview before running the next backup:

```bash
./bin/omarchy-backup backup --dry-run
```

### Interrupted Or Failed Backup

It is safe to stop a running backup with `Ctrl+C`. Restic may leave unreferenced
uploaded chunks, but incomplete snapshots are not useful restore points.

After fixing includes/excludes, rerun:

```bash
./bin/omarchy-backup backup
```

Once you have a successful snapshot, reclaim unreferenced repository data:

```bash
./bin/omarchy-backup prune
```

## Quick Start

Run the CLI from the repository:

```bash
./bin/omarchy-backup doctor
./bin/omarchy-backup config show
./bin/omarchy-backup config validate
```

The first config command creates:

```txt
~/.config/omarchy-backup/config.json
```

Set up Google Drive storage and initialize the restic repository:

```bash
./bin/omarchy-backup setup
```

Password handling follows this order:

1. If `secrets.passwordCommand` is configured, `omarchy-backup` uses it.
2. If the TUI asks for a password, it passes it to the backend environment for that action.
3. Otherwise, commands ask for the repository password when needed.

Avoid passing literal passwords as command-line arguments because they can leak
through shell history or process listings.

Create a backup:

```bash
./bin/omarchy-backup backup
```

List snapshots:

```bash
./bin/omarchy-backup snapshots
```

Restore a snapshot to a staging directory:

```bash
./bin/omarchy-backup restore latest --target ~/Restored/omarchy-backup/latest
```

Restore a selected path from a snapshot:

```bash
./bin/omarchy-backup restore latest ~/Documents --target ~/Restored/omarchy-backup/latest
```

## Commands

```bash
omarchy-backup init
omarchy-backup setup
omarchy-backup tui
omarchy-backup backup [--dry-run]
omarchy-backup snapshots [args...]
omarchy-backup ls <snapshot> [path]
omarchy-backup restore <snapshot> [path] [--target <path>|--original] [--dry-run] [--yes]
omarchy-backup check
omarchy-backup doctor
omarchy-backup remote setup
omarchy-backup remote check
omarchy-backup password setup
omarchy-backup password status
omarchy-backup paths list
omarchy-backup paths include add <path>
omarchy-backup paths include remove <path>
omarchy-backup paths exclude add <pattern>
omarchy-backup paths exclude remove <pattern>
omarchy-backup forget [--dry-run]
omarchy-backup prune
omarchy-backup unlock
omarchy-backup status
omarchy-backup config show
omarchy-backup config validate
omarchy-backup config edit
omarchy-backup config restore [--repository <url>] [--yes]
```

## Tests

Run the shell test suite with:

```bash
./tests/run.sh
```

The tests use fake `restic` and `rclone` commands, so they do not access a real
repository or remote storage.

## Configuration

See [examples/config.google-drive.json](examples/config.google-drive.json).

The default config backs up common personal data paths and excludes generated
directories such as `node_modules`, `.next`, `dist`, caches, Python virtualenvs,
Rust targets, and ISO images.

Every backup also stores a sanitized copy of the `omarchy-backup` config next to
the Restic repository on the remote at:

```txt
/.omarchy-backup/config.json
```

This bootstrap config is copied with `rclone`, not Restic, so it can be restored
before the Restic repository password is available. The `secrets` section is
removed from that remote copy.

On a fresh Omarchy install, restore that config before normal setup:

```bash
./bin/omarchy-backup config restore
```

By default this looks at:

```txt
rclone:gdrive:backups/home
```

You can override it:

```bash
./bin/omarchy-backup config restore --repository rclone:gdrive:backups/laptop
```

Customize protected paths through the CLI:

```bash
./bin/omarchy-backup paths list
./bin/omarchy-backup paths include add ~/Projects
./bin/omarchy-backup paths exclude add '**/coverage'
./bin/omarchy-backup paths include remove ~/Projects
./bin/omarchy-backup paths exclude remove '**/coverage'
```

## Safety

Restore defaults to a staging directory under:

```txt
~/Restored/omarchy-backup/<snapshot>
```

Restoring to original locations requires `--original` and prints a warning before
continuing.
