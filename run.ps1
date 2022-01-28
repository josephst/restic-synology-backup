Write-Output "Removing old container names 'backup-test' if exists"

docker rm -f -v backup-test

Write-Output "Starting backup-test container. Backup of ./dataForBackup/setA to repo ./test/remoteRepo every minute"
Write-Output "Copy from ./dataForBackup/copy (existing local repo) to ./test/remoteRepo every minute"

$dir = $PSScriptRoot

$setA = Join-Path $dir "/dataForBackup/setA"
$copy = Join-Path $dir "/dataForBackup/copy"
$remoteRepo = Join-Path $dir "/test/remoteRepo"

docker run --privileged --name backup-test `
 -h "restic-backup" `
 -e "RESTIC_PASSWORD=Foobar" `
 -e "RESTIC_TAG=test" `
 -e "RESTIC_PASSWORD2=Foobar2" `
 -e "BACKUP_CRON=* * * * *" `
 -e "USE_HEALTHCHECK=N" `
 -v "$($setA):/data" `
 -v "$($copy):/mnt/copy" `
 -v "$($remoteRepo):/mnt/restic" `
 -t restic-synology-backup
