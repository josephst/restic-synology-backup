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

# Forget and Prune local snapshots (ie ones that were backed up to restic)
# Should run before copying snapshots to remote (B2, S3, etc) repo

function Invoke-Maintenance {
    Write-Log "[[Local Maintenance]] Start $(Get-Date)"
    $maintenance_success = $true
    Start-Sleep 5

    # forget snapshots based upon the retention policy
    Write-Log "[[Local Maintenance]] Start forgetting..." 

    try {
        # swap passwords around, 
        $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD

        # run forget on local repo
        # TODO: refactor the forget portions into common script/ function
        $ForgetJson = & $ResticBin forget -r $env:RESTIC_REPOSITORY2 $SnapshotRetentionPolicy --json | ConvertFrom-Json
        $ForgetStatus = $?
        if (-not $ForgetStatus) {
            Write-Log "[[Local Maintenance]] Forget operation completed with errors" -IsErrorMessage
            Write-Log "[[Local Maintenance]] $ForgetJson" -IsErrorMessage
            $ErrorCount++
            $maintenance_success = $false
        }
        else {
            $keepCount = 0
            $removeCount = 0
            $ForgetJson | ForEach-Object { $keepCount += $_.keep.Count
                $removeCount += $_.remove.Count }
            Write-Log "[[Local Maintenance]] Keeping $keepCount snapshots, forgetting $removeCount snapshots"
            Write-Log "[[Local Maintenance]] Forget operation succeeded"
        }

        # prune (remove) data from the backup step. Running this separate from `forget` because
        #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
        Write-Log "[[Local Maintenance]] Start pruning..."
        & $ResticBin prune -r $env:RESTIC_REPOSITORY2 $SnapshotPrunePolicy *>&1 | Write-Log
        if (-not $?) {
            Write-Log "[[Local Maintenance]] Prune operation completed with errors" -IsErrorMessage
            $ErrorCount++
            $maintenance_success = $false
        }
    }
    finally {
        # cleanup and swap passwords back
        $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
        Write-Log "[[Local Maintenance]] End $(Get-Date)"
    }
        
    if ($maintenance_success -eq $true) {
        $Script:ResticStateLocalLastMaintenance = Get-Date
        $Script:ResticStateLocalMaintenanceCounter = 0
    }
}

function Invoke-Datacheck {
    $data_check = @()
    if ($null -ne $ResticStateLastDeepMaintenance) {
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if ($SnapshotDeepMaintenance && $delta.Days -ge $SnapshotDeepMaintenanceDays) {
            # Deep maintenance (ie perform a data check)
            Write-Log "[[Local Maintenance]] Performing deep data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
            Write-Log "[[Local Maintenance]] Will read $SnapshotDeepMaintenanceSize of data"
            $data_check = @("--read-data-subset=$SnapshotDeepMaintenanceSize")
            $Script:ResticStateLocalLastDeepMaintenance = Get-Date
        }
        else {
            Write-Log "[[Local Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
        }
        try {
            # swap passwords around, 
            $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
            & $ResticBin check @data_check *>&1 | Write-Log
            if (-not $?) {
                Write-Log "[[Local Maintenance]] It looks like the data check failed! Possible data corruption?" -IsErrorMessage
                $ErrorCount++
            }
        }
        finally {
            # cleanup and swap passwords back
            $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
        }
    }
    else {
        # set the date, but don't do a check if we've never done a deep maintenance
        $Script:ResticStateLocalLastDeepMaintenance = Get-Date
    }

    Write-Log "[[Local Maintenance]] End $(Get-Date)"
}
