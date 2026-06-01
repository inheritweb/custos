# Custos

```text
   ______           __             
  / ____/_  _______/ /_____  _____
 / /   / / / / ___/ __/ __ \/ ___/
/ /___/ /_/ (__  ) /_/ /_/ (__  ) 
\____/\__,_/____/\__/\____/____/  
```

`custos` is a shell-first backup and restore tool for Linux home directories.
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

Install missing packages with the package manager for your distribution:

```bash
# Arch / Manjaro
sudo pacman -S --needed jq restic rclone

# Debian / Ubuntu
sudo apt-get update
sudo apt-get install jq restic rclone

# Fedora / RHEL family
sudo dnf install jq restic rclone
```

## Install

Install from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/inheritweb/custos/main/scripts/install.sh | bash
```

The installer places project files in:

```txt
~/.local/share/custos
```

and installs the command wrapper at:

```txt
~/.local/bin/custos
```

For a VM test against a branch or commit:

```bash
curl -fsSL https://raw.githubusercontent.com/inheritweb/custos/main/scripts/install.sh | bash -s -- --ref <branch-or-sha>
```

The installer only installs the Custos files and command wrapper. Install
dependencies separately with your distribution's package manager.

Uninstall the local app files, command wrapper, config, and state:

```bash
custos uninstall
```

This keeps rclone configuration and remote backup data. To leave local config and state behind:

```bash
custos uninstall --keep-local-data
```

## Interactive TUI

Launch the interactive terminal UI:

```bash
custos
```

`custos tui` is kept as an explicit alias, but the normal app entry point is
just `custos`.

![Custos TUI screenshot](assets/screenshot.png)

The TUI is a shell frontend over the same commands documented below. It opens on
a repositories list. Select a repository, enter its password if needed, then the
snapshots and actions for that repository become visible. Tab moves between the
active panes.

On first run, the actions pane lets you connect Google Drive, restore an existing
config, or create a new config. Once configured, repositories stay visible as the
top-level choice, and each selected repository has its own backup, restore, path,
repository, and maintenance actions.

If no stored password command is available, the TUI asks for the repository
password once at session start and reuses it for repository actions. Passwords
are passed through the process environment, not as command-line arguments.

## Journeys

### First Backup On This Machine

Install dependencies:

```bash
# Arch / Manjaro
sudo pacman -S --needed jq restic rclone

# Debian / Ubuntu
sudo apt-get update
sudo apt-get install jq restic rclone

# Fedora / RHEL family
sudo dnf install jq restic rclone
```

Check the local environment:

```bash
custos doctor
```

Create or inspect the config. The default config creates one job named `home`
that backs up `~` to `gdrive:backups/home`:

```bash
custos config show
custos jobs list
custos paths list
```

Set up Google Drive and initialize the Restic repository:

```bash
custos setup
```

Preview and run the first backup:

```bash
custos backup --dry-run
custos backup
```

Verify it:

```bash
custos snapshots
custos check
```

### Restore A File Safely

By default, restore goes to a staging directory so local files are not overwritten:

```bash
custos restore latest ~/Documents/file.pdf
```

The default target is:

```txt
~/Restored/custos/latest
```

Restore to the original location only when that is intentional:

```bash
custos restore latest ~/Documents/file.pdf --original
```

### Fresh Linux Restore

On a newly installed machine, install dependencies and configure Google Drive:

```bash
# Arch / Manjaro
sudo pacman -S --needed jq restic rclone

# Debian / Ubuntu
sudo apt-get update
sudo apt-get install jq restic rclone

# Fedora / RHEL family
sudo dnf install jq restic rclone

custos remote setup
```

Restore the saved `custos` config from the remote:

```bash
custos config restore
```

Then inspect snapshots and restore to a staging directory:

```bash
custos snapshots
custos restore latest --target ~/Restored/custos/latest
```

Use `--original` only when you want Restic to write back to the original paths.

### Change What Gets Backed Up

List the active include and exclude rules for the default job:

```bash
custos paths list
```

For a specific job, pass `--job`:

```bash
custos paths --job home list
```

Add or remove protected paths:

```bash
custos paths include add ~/Projects
custos paths include remove ~/Projects
```

Add or remove exclude patterns:

```bash
custos paths exclude add '**/*.qcow2'
custos paths exclude remove '**/*.qcow2'
```

Preview before running the next backup:

```bash
custos backup --dry-run
```

### Multiple Repositories

Custos stores backup jobs in `config.json`. Each job has one source set and one
remote repository. The default job is `home`, which links `~` to
`gdrive:backups/home`.

Add another job:

```bash
custos jobs add data --source /dev/mymountpoint --remote gdrive:backups/data
```

Run commands against a specific job:

```bash
custos backup --job data
custos snapshots --job data
custos restore --job data latest --target ~/Restored/custos/data
```

Set the default job used by commands that do not pass `--job`:

```bash
custos jobs default data
```

### Interrupted Or Failed Backup

It is safe to stop a running backup with `Ctrl+C`. Restic may leave unreferenced
uploaded chunks, but incomplete snapshots are not useful restore points.

After fixing includes/excludes, rerun:

```bash
custos backup
```

Once you have a successful snapshot, reclaim unreferenced repository data:

```bash
custos prune
```

## Quick Start

Run command-line checks:

```bash
custos doctor
custos config show
custos config validate
```

The first config command creates:

```txt
~/.config/custos/config.json
```

Current configs use version 2 and store one or more backup jobs. Older version 1
configs are migrated automatically the next time Custos reads them.

Set up Google Drive storage and initialize the restic repository:

```bash
custos setup
```

Password handling follows this order:

1. If `secrets.passwordCommand` is configured, `custos` uses it.
2. If the TUI asks for a password, it passes it to the backend environment for that action.
3. Otherwise, commands ask for the repository password when needed.

Avoid passing literal passwords as command-line arguments because they can leak
through shell history or process listings.

Create a backup:

```bash
custos backup
```

List snapshots:

```bash
custos snapshots
```

Restore a snapshot to a staging directory:

```bash
custos restore latest --target ~/Restored/custos/latest
```

Restore a selected path from a snapshot:

```bash
custos restore latest ~/Documents --target ~/Restored/custos/latest
```

## Commands

```bash
custos init
custos setup
custos
custos tui  # explicit TUI alias
custos jobs list
custos jobs add <id> --source <path> --remote <remote:path> [--name <name>]
custos jobs remove <id>
custos jobs default <id>
custos backup [--job <id>] [--dry-run]
custos snapshots [--job <id>] [args...]
custos ls [--job <id>] <snapshot> [path]
custos restore [--job <id>] <snapshot> [path] [--target <path>|--original] [--dry-run] [--yes]
custos check [--job <id>]
custos doctor
custos remote setup
custos remote check
custos password setup
custos password status
custos paths [--job <id>] list
custos paths [--job <id>] include add <path>
custos paths [--job <id>] include remove <path>
custos paths [--job <id>] exclude add <pattern>
custos paths [--job <id>] exclude remove <pattern>
custos forget [--job <id>] [--dry-run]
custos prune [--job <id>]
custos unlock [--job <id>]
custos status [--job <id>]
custos config show
custos config validate
custos config edit
custos config restore [--repository <url>] [--yes]
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

Every backup also stores a sanitized copy of the `custos` config next to
the Restic repository on the remote at:

```txt
/.custos/config.json
```

This bootstrap config is copied with `rclone`, not Restic, so it can be restored
before the Restic repository password is available. The `secrets` section is
removed from that remote copy.

On a fresh Linux install, restore that config before normal setup:

```bash
custos config restore
```

By default this looks at:

```txt
rclone:gdrive:backups/home
```

You can override it:

```bash
custos config restore --repository rclone:gdrive:backups/laptop
```

Customize protected paths through the CLI:

```bash
custos paths list
custos paths include add ~/Projects
custos paths exclude add '**/coverage'
custos paths include remove ~/Projects
custos paths exclude remove '**/coverage'
```

## Safety

Restore defaults to a staging directory under:

```txt
~/Restored/custos/<snapshot>
```

Restoring to original locations requires `--original` and prints a warning before
continuing.

## Acknowledgements

The TUI look, feel, and interaction model are inspired by
[Impala](https://github.com/pythops/impala), especially its static pane layout,
focused-border navigation, and modal prompts.
