#!/usr/bin/pwsh

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
# TODO: put these in a configuration directory

# backup configuration variables
$CommonScript = Join-Path $PSScriptRoot "common.ps1"

# =========== end configuration =========== #

# Load configuration
# . $ConfigScript

# Common functions
. $CommonScript

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

function Get-LocalMaintenanceDue {
    # skip maintenance if disabled
    if ($SnapshotLocalMaintenanceEnabled -eq $false) {
        Write-Log "[[Maintenance]] Skipped - maintenance disabled"
        return $false
    }

    # skip maintenance if it's been done recently
    # TODO: FINISH CONVERTING VARIABLES TO resticstateLOCALlastmaintenance...
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

function Invoke-Maintenance {
    Write-Log "[[Maintenance]] Start $(Get-Date)"
    $maintenance_success = $true
    Start-Sleep 5

    # forget snapshots based upon the retention policy
    Write-Log "[[Maintenance]] Start forgetting..." 
    $ForgetJson = & $ResticBin forget $SnapshotRetentionPolicy --json | ConvertFrom-Json
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
    Write-Log "[[Maintenance]] Start pruning..."
    & $ResticBin prune $SnapshotPrunePolicy *>&1 | Write-Log
    if (-not $?) {
        Write-Log "[[Maintenance]] Prune operation completed with errors" -IsErrorMessage
        $ErrorCount++
        $maintenance_success = $false
    }

        
    if ($maintenance_success -eq $true) {
        $Script:ResticStateLastMaintenance = Get-Date
        $Script:ResticStateMaintenanceCounter = 0
    }
}

function Invoke-Datacheck {
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
        else {
            Write-Log "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
        }

        & $ResticBin check @data_check *>&1 | Write-Log
        if (-not $?) {
            Write-Log "[[Maintenance]] It looks like the data check failed! Possible data corruption?" -IsErrorMessage
            $ErrorCount++
        }
    }
    else {
        # set the date, but don't do a check if we've never done a deep maintenance
        $Script:ResticStateLastDeepMaintenance = Get-Date
    }

    Write-Log "[[Maintenance]] End $(Get-Date)"
}
