Write-Output "Removing old container names 'backup-test' if exists"

docker rm -f -v backup-test

Write-Output "Starting backup-test container. Backup of ./dataForBackup/setA to repo ./test/remoteRepo every minute"
Write-Output "Copy from ./dataForBackup/copy (existing local repo) to ./test/remoteRepo every minute"

$dir = $PSScriptRoot

$configDir = Join-Path $dir "/config"
$setA = Join-Path $dir "/dataForBackup/setA"
$copy = Join-Path $dir "/dataForBackup/copy"
$remoteRepo = Join-Path $dir "/test/remoteRepo"

$USE_HEALTHCHECK = $env:USE_HEALTHCHECK ?? "N"
$HC_PING = $env:HC_PING ?? ""
$RANDOM_DELAY = [int]$env:RANDOM_DELAY ?? 0  # dev env = no random sleep delays

docker run --privileged --name backup-test `
    -h "restic-backup" `
    -e "RESTIC_PASSWORD=Foobar" `
    -e "RESTIC_TAG=test" `
    -e "RESTIC_PASSWORD2=Foobar2" `
    -e "BACKUP_CRON=* * * * *" `
    -e "USE_HEALTHCHECK=$USE_HEALTHCHECK" `
    -e "HC_PING=$HC_PING" `
    -e "RANDOM_DELAY=$RANDOM_DELAY"`
    -v "$($setA):/data" `
    -v "$($copy):/mnt/copy" `
    -v "$($remoteRepo):/mnt/restic" `
    -v "$($configDir):/etc/backup" `
    -t restic-synology-backup
