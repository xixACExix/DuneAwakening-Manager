# Simple Dune Awakening Manager by Ace

Local Windows GUI manager for the Dune Awakening Self-Hosted Server package.

## Download

For normal use, download the latest release ZIP:

[Simple Dune Awakening Manager by Ace v1.0.0](https://github.com/xixACExix/Simple-Dune-Awakening-Manager/releases/tag/v1.0.0)

The source files in this repository mirror the release package so they can be reviewed before downloading.

## Run

```powershell
.\Start-Simple-Dune-Awakening-Manager.bat
```

The launcher opens the GUI and requests Administrator access automatically. Administrator access is required for Hyper-V VM setup, VM start/stop, switch setup, and repair actions.

## Server Package Detection

Simple Dune Awakening Manager looks for the official Steam server package through Steam registry data, Steam `libraryfolders.vdf`, and common Steam library paths across local drives. You can override detection by setting:

```powershell
$env:DUNE_SERVER_ROOT = "<your Steam library>\steamapps\common\Dune Awakening Self-Hosted Server"
```

If the package is not found, the manager shows `Steam server package not found` and keeps VM-only actions available where possible.

## Main Features

- First-time setup automation: VM import, Hyper-V switch setup, VM memory, SSH key setup, password change, IP setup, bootstrap upload, and initial battlegroup setup.
- Region selection during first-time setup.
- Server settings editor for world title, Sietch name, join password, PvP, security zones, resource multipliers, storms, sandworm behavior, durability, deterioration, and building limits.
- Reinstall-safe local backups and restores for the battlegroup database plus manager-edited ini settings.
- Health watchdog with optional safe auto-repair.
- Manual repair button for failed startup/schema pods and stopped battlegroups.
- Quick actions for status, start, restart, stop, update, local backup, logs, file browser, and Director.
- Existing install detection that locks reinstall behind `Replace existing VM / reinstall`.

## Health Watchdog

The Actions tab has a `Health Watchdog` section:

- `Check Health` asks the VM for live battlegroup, database, gateway, and game-server readiness.
- `Run Repair` starts the VM/world if needed and removes failed one-shot database schema pods so the official operators can recreate them.
- `Enable watchdog` runs health checks on a timer.
- `Auto repair` lets timed checks apply the same safe repairs.
- `Keep world running` allows the watchdog to request a start when the battlegroup is stopped.

The watchdog does not delete saves or reinstall the server.

## Settings

1. Open `Start-Simple-Dune-Awakening-Manager.bat`.
2. Go to `Settings`.
3. Press `Load Current`.
4. Edit the values you want.
5. Press `Apply Settings`.

The settings action backs up `UserEngine.ini` and `UserGame.ini` inside the VM before changing them. `Restart after apply` restarts the battlegroup so game servers pick up the new values immediately.

## Backups And Restore

Use `Actions` -> `Local Backup` to create a reinstall-safe backup under:

```text
Simple-Dune-Awakening-Manager\backups
```

The local backup includes the official battlegroup database dump, the battlegroup YAML when available, and the `UserEngine.ini` / `UserGame.ini` settings edited by the manager.

To restore after a reinstall:

1. Run first-time setup so the VM and battlegroup exist again.
2. Go to `Actions` -> `Restore Backup`.
3. Select the `.tar.gz` archive from `Simple-Dune-Awakening-Manager\backups`.
4. Confirm the restore warning.

Restore stops the battlegroup, imports the selected database backup, restores manager-edited ini files when present, applies default user settings, and starts the battlegroup again.

## Cleanup

To remove generated/imported Dune server instances without touching the Steam server package, run:

```powershell
.\Remove-InstalledInstances.bat
```

## Source

The PowerShell source is published in the repository root for review. The release ZIP contains the same manager scripts plus the required SSH DLL in the layout expected by the launcher.

## License / Use

Simple Dune Awakening Manager by Ace may be used, copied, modified, and shared for personal, private, or community Dune Awakening self-hosted server management.

Do not sell it, bundle it as paid software, or present it as an official Funcom tool. Dune Awakening and related names belong to their owners.

This tool changes local Hyper-V and server files at your direction. Keep backups before updates, imports, or reinstalls.

Signed,
Ace
