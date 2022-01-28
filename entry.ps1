#!/usr/bin/pwsh

Write-Output "Starting container..."

restic snapshots | Out-Null
$status=$?
Write-Output "Check Repo status: $status"

if ($status -eq $false) {
    Write-Error "Restic repository $env:RESTIC_REPOSITORY does not exist."
    exit 1
}

Write-Information "Setup backup."

Write-Output "Setup backup cron job with cron expression BACKUP_CRON: $env:BACKUP_CRON"
Write-Output "$env:BACKUP_CRON /usr/bin/flock -n /var/run/backup.lock pwsh -c '. /bin/backup/backup && Invoke-Main' >> /var/log/cron.log 2&>1" `
 | Out-File "/var/spool/cron/crontabs/root"

# Make sure log file exists before starting tail
touch "/var/log/cron.log"

crond

Write-Output "Container started with args: $args"

Invoke-Expression "$args"
