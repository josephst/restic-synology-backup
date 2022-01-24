$ScriptDir = $PSScriptRoot
$StateFile = Join-Path $ScriptDir "state.xml"
$LocalExcludeFile = Join-Path $ScriptDir "local.exclude"
$LogPath = Join-Path $ScriptDir "logs"
$LogRetentionDays = 30
$InternetTestAttempts = 10
$GlobalRetryAttempts = 4
$IgnoreMissingBackupSources = $false

# Restic bin
$ResticBin = "/usr/bin/restic"

# maintenance configuration
$SnapshotMaintenanceEnabled = $true
$SnapshotRetentionPolicy = @("--group-by", "host,tags", "--keep-daily", "30", "--keep-weekly", "52", "--keep-monthly", "24", "--keep-yearly", "10")
$SnapshotPrunePolicy = @("--max-unused", "1%")
$SnapshotMaintenanceInterval = 7
$SnapshotMaintenanceDays = 30
$SnapshotDeepMaintenanceDays = 90;

# Healthchecks.io configuration
$UseHealthcheck = $true

# Paths to backup
$BackupSources = @{}
$BackupSources["/data"] = @()
