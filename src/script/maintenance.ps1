#!/usr/bin/pwsh

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
# TODO: put these in a configuration directory

# =========== end configuration =========== #

# note that local data checks are performed as same schedule as remote data checks
function Get-MaintenanceDue {
    # skip maintenance if disabled
    if ($SnapshotMaintenanceEnabled -eq $false) {
        Write-Log "[[Maintenance]] Skipped - maintenance disabled"
        return $false
    }

    # skip maintenance if it's been done recently
    if (($null -ne $ResticStateLastMaintenance) -and ($null -ne $ResticStateMaintenanceCounter)) {
        $Script:ResticStateMaintenanceCounter += 1
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if (($delta.Days -lt $SnapshotMaintenanceDays) -and ($ResticStateMaintenanceCounter -lt $SnapshotMaintenanceInterval)) {
            Write-Log "[[Maintenance]] Skipped - last maintenance $ResticStateLastMaintenance ($($delta.Days) days, $ResticStateMaintenanceCounter backups ago)"
            return $false # false = maintenance is NOT due
        }
    }
    return $true
}

function Invoke-RemoteMaintenance {
    Write-Log "[[Remote Maintenance]] Start $(Get-Date)"
    $success = Invoke-Maintenance

    if ($success -eq $true) {
        $Script:ResticStateLastMaintenance = Get-Date
        $Script:ResticStateMaintenanceCounter = 0
    }

    Write-Log "[[Remote Maintenance]] Finished"
}

function Invoke-LocalMaintenance {
    Write-Log "[[Local Maintenance]] Start $(Get-Date)"
    try {
        Switch-RepositoryPasswords
        Invoke-Maintenance -CheckLocalData
    }
    finally {
        Switch-RepositoryPasswords
    }
    Write-Log "[[Local Maintenance]] Finished"
}

function Invoke-RemoteDatacheck {
    Write-Log "[[Remote Datacheck]] Start $(Get-Date)"
    Invoke-Datacheck
    Write-Log "[[Remote Datacheck]] Finished"
}

function Invoke-LocalDatacheck {
    Write-Log "[[Local Datacheck]] Start $(Get-Date)"
    try {
        Switch-RepositoryPasswords
        Invoke-Datacheck -CheckLocalData
    }
    finally {
        Switch-RepositoryPasswords
    }
    Write-Log "[[Local Datacheck]] Finished"
}

# PRIVATE
# Use Invoke-LocalMaintenance or Invoke-RemoteMaintenance as necessary
function Invoke-Maintenance {
    [CmdletBinding()]
    param (
        [switch]
        $CheckLocalData
    )

    $maintenance_success = $true

    $repoPath = $env:RESTIC_REPOSITORY
    if ($CheckLocalData) {
        $repoPath = $env:RESTIC_REPOSITORY2
    }

    # forget snapshots based upon the retention policy
    Write-Log "[[Maintenance]] Start forgetting from $repoPath..." 
    $ForgetJson = & $ResticBin forget -r $repoPath $SnapshotRetentionPolicy --json | ConvertFrom-Json
    $ForgetStatus = $?
    if (-not $ForgetStatus) {
        Write-Log "[[Maintenance]] Forget operation completed with errors" -IsErrorMessage
        Write-Log "[[Maintenance]] $ForgetJson" -IsErrorMessage
        $ErrorCount++
        $maintenance_success = $false
    }
    else {
        $keepCount = 0
        $removeCount = 0
        $ForgetJson | ForEach-Object { $keepCount += $_.keep.Count
            $removeCount += $_.remove.Count }
        Write-Log "[[Maintenance]] Keeping $keepCount snapshots, forgetting $removeCount snapshots"
        Write-Log "[[Maintenance]] Forget operation succeeded"
    }

    # prune (remove) data from the backup step. Running this separate from `forget` because
    #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
    Write-Log "[[Maintenance]] Start pruning from $repoPath..."
    & $ResticBin prune -r $repoPath $SnapshotPrunePolicy *>&1 | Write-Log
    if (-not $?) {
        Write-Log "[[Maintenance]] Prune operation completed with errors" -IsErrorMessage
        $ErrorCount++
        $maintenance_success = $false
    }

    return $maintenance_success
}

# PRIVATE
# Use Invoke-LocalDatacheck or Invoke-RemoteDatacheck as needed
# $localDatacheck = true if checking data on NAS, false/ unset for remote data
function Invoke-Datacheck {
    [CmdletBinding()]
    param (
        [switch]
        $CheckLocalData
    )

    $repoPath = $env:RESTIC_REPOSITORY
    if ($CheckLocalData) {
        $repoPath = $env:RESTIC_REPOSITORY2
    }

    $data_check = @()
    if ($null -ne $ResticStateLastDeepMaintenance) {
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if ($SnapshotDeepMaintenance && $delta.Days -ge $SnapshotDeepMaintenanceDays) {
            # Deep maintenance (ie perform a data check)
            Write-Log "[[Maintenance]] Performing deep data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
            Write-Log "[[Maintenance]] Will read $SnapshotDeepMaintenanceSize of data"
            $data_check = @("--read-data-subset=$SnapshotDeepMaintenanceSize")
            $Script:ResticStateLastDeepMaintenance = Get-Date
        }
        elseif ($CheckLocalData) {
            Write-Log "[[Maintenance]] Working with locally stored data, will perform deep check"
            Write-Log "[[Maintenance]] Will read $SnapshotDeepMaintenanceSize of data"
            $data_check = @("--read-data-subset=$SnapshotDeepMaintenanceSize")
        }
        else {
            Write-Log "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
        }

        & $ResticBin check -r $repoPath @data_check *>&1 | Write-Log
        if (-not $?) {
            Write-Log "[[Maintenance]] It looks like the data check failed! Possible data corruption?" -IsErrorMessage
            $ErrorCount++
        }
    }
    else {
        # only set deep maintenance date for remote data checks
        if (-not $CheckLocalData) {
            # set the date, but don't do a check if we've never done a deep maintenance
            $Script:ResticStateLastDeepMaintenance = Get-Date
        }
    }

    Write-Log "[[Maintenance]] End $(Get-Date)"
}
