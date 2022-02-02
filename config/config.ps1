$ScriptDir = $PSScriptRoot # /etc/backup
$StateFile = Join-Path $ScriptDir "state.xml"
$LocalExcludeFile = Join-Path $ScriptDir "local.exclude"
$LogPath = $LogPath ?? "/var/log/restic/backup.log"
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
$UseHealthcheck = $Env:USE_HEALTHCHECK -eq "Y" ? $true : $false
$hc_url ??= $env:HC_PING

# Copy an existing repo to the destination repo
$CopyLocalRepo = $Env:COPY_LOCAL_REPO -eq "Y" ? $true : $false

# Paths to backup
$BackupSources = @("/data")
# $BackupSources["/data"] = @()
