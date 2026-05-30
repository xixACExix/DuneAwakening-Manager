# How DuneManager by Ace Works

DuneManager by Ace is a local Windows PowerShell GUI. It does not replace the official Dune Awakening self-hosted server package. It finds that package on your Steam library drive and calls the official scripts in the background.

## Startup

`Start-DuneManager.bat` relaunches the GUI as Administrator when needed. Administrator access is required for Hyper-V management.

The release ZIP includes the SSH.NET dependency used for first-time SSH key setup. Source checkouts can run without the bundled `lib` folder; the manager downloads the same NuGet package when that dependency is first needed.

## First-Time Setup

The setup flow imports the packaged VM, configures Hyper-V networking, starts the VM, installs an SSH key, changes the VM password, writes the player connection IP, uploads the bootstrap script, and runs the official battlegroup setup inside the VM.

The reinstall path is locked behind `Replace existing VM / reinstall` so an existing server is not wiped by accident.

## Settings

The Settings tab edits the supported `UserEngine.ini` and `UserGame.ini` values. Before changing anything, it creates timestamped backups inside the VM. When `Restart after apply` is checked, it restarts the battlegroup so live game servers pick up the settings.

## Local Backups

The `Local Backup` button first asks the official battlegroup tool to create a database dump inside the VM, then downloads that dump into `DuneManager\backups` as a `.tar.gz` archive. The archive also includes the battlegroup YAML when available and the manager-edited `UserEngine.ini` / `UserGame.ini` files.

Because the archive lives outside the VM, it can survive a VM reinstall. After reinstalling, run first-time setup, use `Restore Backup`, select the local archive, and confirm the warning. Restore stages the dump into the new battlegroup, runs the official import flow, restores manager-edited ini files when present, applies default user settings, and starts the battlegroup again.

## Health Watchdog

The watchdog checks the VM, battlegroup, database, gateway, Director, and map server readiness.

Safe repair can:

- Start the VM/world when `Keep world running` is enabled.
- Delete failed one-shot database schema pods so the official operator can recreate them.
- Request a battlegroup start when the world is stopped.

Safe repair does not delete saves, databases, or reinstall the VM.

## Cleanup

`Remove-InstalledInstances.bat` removes generated/imported Dune server instances and local generated SSH/settings data. It does not remove the Steam server package.

## Notes

The manager searches Steam registry data, Steam `libraryfolders.vdf`, and common Steam library paths. If your Steam server package is not found, set `DUNE_SERVER_ROOT` before launching the manager:

```powershell
$env:DUNE_SERVER_ROOT = "<your Steam library>\steamapps\common\Dune Awakening Self-Hosted Server"
```
