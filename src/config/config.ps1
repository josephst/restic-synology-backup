$ConfigDir = $PSScriptRoot # /etc/backup
$LogPath = $LogPath ?? "/var/backup/restic.log"
$StateFile = Join-Path $ConfigDir "state.xml"
$LocalExcludeFile = Join-Path $ConfigDir "local.exclude"
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
$SnapshotMaintenanceInterval = $Env:RESTIC_MAINT_INTERVAL ?? 7
$SnapshotMaintenanceDays = $Env:RESTIC_MAINT_DAYS ?? 30
$SnapshotDeepMaintenance = $Env:RESTIC_DEEP_MAINT -eq "Y"
$SnapshotDeepMaintenanceDays = $Env:RESTIC_DEEP_MAINT_DAYS ?? 90
$SnapshotDeepMaintenanceSize = $Env:RESTIC_DEEP_MAINT_SIZE ?? "100%"

# Healthchecks.io configuration
$UseHealthcheck = $Env:USE_HEALTHCHECK -eq "Y"
$hc_url ??= $Env:HC_PING

# Copy an existing repo to the destination repo
$CopyLocalRepo = $Env:COPY_LOCAL_REPO -eq "Y"

# Paths to backup
$BackupSources = @("/data")
# $BackupSources["/data"] = @()
