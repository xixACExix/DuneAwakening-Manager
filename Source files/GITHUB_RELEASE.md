# DuneManager by Ace v1.0.0

## Release Summary

DuneManager by Ace is a Windows GUI helper for the Dune Awakening Self-Hosted Server package. It wraps the official Steam server scripts with a friendlier interface for first-time setup, battlegroup actions, server settings, backups, logs, and health repair.

## Highlights

- Automated first-time setup for the Hyper-V VM and battlegroup.
- Region choice during install.
- Server settings editor for world title, Sietch name, join password, PvP, security zones, resource multipliers, storms, sandworm behavior, durability, deterioration, and building limits.
- Local backup and restore flow for reinstall-safe database and manager-edited ini backups.
- Health Watchdog with optional safe auto-repair.
- Manual repair for failed startup/schema pods and stopped battlegroups.
- Existing install detection that locks reinstall behind a deliberate checkbox.
- Ace-signed About / License message in the manager.
- GUI-only release; old command-line launcher removed.

## How It Works

1. Download and extract the release ZIP.
2. Run `Start-DuneManager.bat`.
3. Approve the Administrator prompt.
4. Use `First-Time Setup` for a fresh install, or `Actions` and `Settings` for an existing install.
5. Use `Health Watchdog` to check health, repair stuck startup, or keep the world running.

The manager calls the official Dune Awakening self-hosted server scripts from the local Steam server package. It does not include or redistribute the game server package.

## Upload Checklist

Attach this file to a GitHub release:

```text
DuneManager-v1.0.0.zip
```

Suggested tag:

```text
v1.0.0
```

Suggested release title:

```text
DuneManager by Ace v1.0.0
```

## License / Use

DuneManager by Ace may be used, copied, modified, and shared for personal, private, or community Dune Awakening self-hosted server management.

Do not sell it, bundle it as paid software, or present it as an official Funcom tool. Dune Awakening and related names belong to their owners.

Signed,
Ace
