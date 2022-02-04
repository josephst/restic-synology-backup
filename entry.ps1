#!/usr/bin/pwsh

Write-Output "Starting container..."

restic snapshots | Out-Null
$status = $?
Write-Output "Check Repo status: $status"

if ($status -eq $false) {
    Write-Error "[ERROR] Restic repository $env:RESTIC_REPOSITORY does not exist."
    exit 1
}

Write-Output "Setup backup cron job with cron expression BACKUP_CRON: $env:BACKUP_CRON"
Write-Output "$env:BACKUP_CRON /usr/bin/flock -n /var/run/backup.lock pwsh /bin/backup/backup.ps1 >> /var/log/cron.log 2&>1" `
| Out-File -Append "/var/spool/cron/crontabs/root"

# prevent cron.log from getting too large
# wipe file at 00:15 on the first of each month
Write-Output '15 0 1 * * printf "" > /var/log/cron.log' | Out-File -Append "/var/spool/cron/crontabs/root"

# Make sure log file exists before starting tail
touch "/var/log/cron.log"

crond

Write-Output "started with args: $args"

Invoke-Expression "$args"

