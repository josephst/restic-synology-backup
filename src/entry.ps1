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

# make sure only 1 existance of this line exists (so that it's not added with each container reboot)
crontab -l | Where-Object { $_ -notmatch 'backup.lock' } | crontab -
$(crontab -l | Out-String).TrimEnd() + "

$env:BACKUP_CRON /usr/bin/flock -n /var/run/backup.lock pwsh /bin/backup/main.ps1 >> /var/log/cron.log 2&>1" `
| crontab -

# Make sure log file exists before starting tail
touch "/var/log/cron.log"

crond

Write-Output "started with args: $args"

Invoke-Expression "$args"

