Write-Output "Removing old container names 'backup-test' if exists"

docker rm -f -v backup-test

Write-Output "Starting backup-test container. Backup of ./dataForBackup/setA to repo ./test/remoteRepo every minute"
Write-Output "Copy from ./dataForBackup/copy (existing local repo) to ./test/remoteRepo every minute"

$dir = $PSScriptRoot

Write-Output $dir

docker run --privileged --name backup-test `
 -e "RESTIC_PASSWORD=Foobar" `
 -e "RESTIC_TAG=test" `
 -e "RESTIC_PASSWORD2=Foobar2" `
 -e "BACKUP_CRON=* * * * *" `
 -e "USE_HEALTHCHECK=N" `
 -v "$dir/dataForBackup/setA:/data" `
 -v "$dir/dataForBackup/copy:/mnt/copy" `
 -v "$dir/test/remoteRepo:/mnt/restic" `
 -t restic-synology-backup
