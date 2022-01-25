#!/usr/bin/pwsh

Write-Output "Starting container..."

restic snapshots $Env:RESTIC_INIT_ARGS | Out-Null

$status=$?
Write-Output "Check Repo status $status"

. /bin/backup/backup.ps1
Invoke-Main
