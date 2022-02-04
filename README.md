# Restic Synology Backup (with Docker)

Current status: PRE-ALPHA. Prone to breaking, data deletion, etc. Not for production use.

A Docker container meant to backup a Synology NAS (or any other network-attached storage)
to a remote location such as Backblaze's B2 or Amazon's S3, using Docker
and Restic to backup multiple folders (and optionally, local Restic repos)
to another location.

Heavily inspired by [kmwoley's restic-windows-backup](https://github.com/kmwoley/restic-windows-backup)
and [lobaro's restic-backup-docker](https://github.com/lobaro/restic-backup-docker).

Unlike other options, this script also includes support for copying an existing Restic repository,
which is ideal for NAS devices, which may serve as a target for local PCs backing up with Restic
and additionally have additional backup that needs to be backed up.

## Goals
1. Safely backup data from local folders to a local or remote Restic repository
2. Copy existing Restic backups to a local or remote Restic repository
3. Take advantage of Restic's data de-duplication to save storage for data
that is both on local PCs backed up to the NAS and additionally on the NAS
4. Provide support for forgetting old backups and testing backups

## TODO
- [x] ⌚ Cron: add support for cron to keep the container running and perform backups every day (or every 1m, for testing)
- [x] 📰 Better logging: log output from each script run (or cron job trigger) to its own file
and clean up the previous file at the start of each run
- [x] 🖨 Use `--json` flag and convert to Powershell objects for better reporting from commands
- [X] 💾 Store details about previous backups (success/ failure, date, amount backed up) as `[pscustomobject]` list
which can be exported/ read from a CSV file
- [x] 🚧 Configuration should be more based on environment variables (which can be changed more easily)
and less on `config.ps1` (which is hard to modify once docker container is created).
Alternatively, put config files into a volume which is mounted (would make modifying `local.exclude` easier)
- [x] 💾 Store `state.xml` file in a docker volume to persist information (such as last maintenance date)
between container creations/ deletions.
- [ ] 🧹 `restic forget` should also clean up the local Restic repo (the repo that local PCs back up to).
Current behavior is to work only on the remote repo
- [x] 🖨 Dockerfile should add a cron job for backups and then `tail -f` log file output


# Development

There are two ways to develop & test the repo:
- VSCode Devcontainer: creates a new Docker devcontainer for VSCode to use.
Helpful for getting a Powershell terminal in the Docker instance to test commands.
Good for rapid iteration and making changes to `backup.ps1` script.
  - The `backup_test.ps1` script is meant to be run inside this container.
  It makes sure that data backup & restore is working properly and also creates a second repo
  to test copying between repos. 
  - ⚠ Depends on a `.devcontainer/devcontainer.env` script to override some Docker variables
  such as `HC_PING` and `RESTIC_PASSWORD`
- `build.ps1` and `run.ps1` scripts: builds a new copy of the container and run a test backup
  - Before running for the first time, make sure to initialize the remote repo
  (optionally, using an existing repo if copying from existing Restic backups):
  ```
  restic init -r ./test/remoteRepo --copyChunkerParams --repo2 ./dataForBackup/copy
  ```

## Assumptions
Script assumes that local repo and remote repo are already initialized.
The `backup_test.ps1` script will create new repos as necessary.

⚠ DANGER: make sure that no important directories are attached when running `backup_test.ps1`
as they may be filled with additional (or junk) data when the backup_test script runs.
By default, the devcontainer only mounts `./dataForBackup` and `./test` folders but it's still worth
taking a look to make sure that no production data/ backup is mounted at `/mnt/restic` or `/mnt/copy`
in the Docker container.

## Misc
To enter the test container (such as to run `restic` to set up repos or perform restores):

```
docker exec -ti backup-test /usr/bin/pwsh
```
