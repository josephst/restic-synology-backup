# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
$SecretsScript = Join-Path $PSScriptRoot "secrets.ps1"

# backup configuration variables
$ConfigScript = Join-Path $PSScriptRoot "config.ps1"

# =========== end configuration =========== #

# globals for state storage
$Script:ResticStateRepositoryInitialized = $null
$Script:ResticStateLastMaintenance = $null
$Script:ResticStateLastDeepMaintenance = $null
$Script:ResticStateMaintenanceCounter = $null

function Get-BackupState {
    if (Test-Path $StateFile) {
        Import-Clixml $StateFile | ForEach-Object { Set-Variable -Scope Script $_.Name $_.Value }
    }
}
function Set-BackupState {
    Get-Variable ResticState* | Export-Clixml $StateFile
}

# unlock the repository if need be
function Invoke-Unlock {
    Param($SuccessLog, $ErrorLog)

    $locks = & $ResticBin list locks --no-lock -q 3>&1 2>> $ErrorLog
    if ($locks.Length -gt 0) {
        # unlock the repository (assumes this machine is the only one that will ever use it)
        & $ResticBin unlock 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
        Write-Output "[[Unlock]] Repository was locked. Unlocking. Past script failure?" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        Start-Sleep 120 
    }
}

function New-Repo {
    Write-Output "[[Init]] Creating new restic repository with restic init"
    & $ResticBin init
    
    if (-not $?) {
        Write-Output "[[Init]] Failed to init the repository: $($Env:RESTIC_REPOSITORY)"
        exit 1
    }
}

function Invoke-Maintenance {
    Param($SuccessLog, $ErrorLog)
    
    # skip maintenance if disabled
    if ($SnapshotMaintenanceEnabled -eq $false) {
        Write-Output "[[Maintenance]] Skipped - maintenance disabled" | Tee-Object -Append $SuccessLog
        return
    }

    # skip maintenance if it's been done recently
    if (($null -ne $ResticStateLastMaintenance) -and ($null -ne $ResticStateMaintenanceCounter)) {
        $Script:ResticStateMaintenanceCounter += 1
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if (($delta.Days -lt $SnapshotMaintenanceDays) -and ($ResticStateMaintenanceCounter -lt $SnapshotMaintenanceInterval)) {
            Write-Output "[[Maintenance]] Skipped - last maintenance $ResticStateLastMaintenance ($($delta.Days) days, $ResticStateMaintenanceCounter backups ago)" | Tee-Object -Append $SuccessLog
            return
        }
    }

    Write-Output "[[Maintenance]] Start $(Get-Date)" | Tee-Object -Append $SuccessLog
    $maintenance_success = $true
    Start-Sleep 120

    # forget snapshots based upon the retention policy
    Write-Output "[[Maintenance]] Start forgetting..." | Tee-Object -Append $SuccessLog
    & $ResticBin forget $SnapshotRetentionPolicy 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
    if (-not $?) {
        Write-Output "[[Maintenance]] Forget operation completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        $maintenance_success = $false
    }

    # prune (remove) data from the backup step. Running this separate from `forget` because
    #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
    Write-Output "[[Maintenance]] Start pruning..." | Tee-Object -Append $SuccessLog
    & $ResticBin prune $SnapshotPrunePolicy 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
    if (-not $?) {
        Write-Output "[[Maintenance]] Prune operation completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        $maintenance_success = $false
    }

    # perform quick data check (full data checks are done by datacheck.ps1)
    Write-Output "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)" | Tee-Object -Append $SuccessLog
    Write-Output "[[Maintenance]] Run `datacheck.ps1` for a full data check" | Tee-Object -Append $SuccessLog

    & $ResticBin check @data_check 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog

    Write-Output "[[Maintenance]] End $(Get-Date)" | Tee-Object -Append $SuccessLog
    
    if ($maintenance_success -eq $true) {
        $Script:ResticStateLastMaintenance = Get-Date
        $Script:ResticStateMaintenanceCounter = 0
    }
}

function Invoke-Backup {
    Param($SuccessLog, $ErrorLog)

    Write-Output "[[Backup]] Start $(Get-Date)" | Tee-Object -Append $SuccessLog
    $return_value = $true
    $starting_location = Get-Location
    ForEach ($item in $BackupSources.GetEnumerator()) {

        # Get the source drive letter or identifier and set as the root path
        $root_path = $item.Key
        $tag = $item.Key

        Write-Output "[[Backup]] Start $(Get-Date) [$tag]" | Tee-Object -Append $SuccessLog
        
        # build the list of folders to backup
        $folder_list = New-Object System.Collections.Generic.List[System.Object]
        if ($item.Value.Count -eq 0) {
            # backup everything in the root if no folders are provided
            $folder_list.Add($root_path)
        }
        else {
            # Build the list of folders from settings
            ForEach ($path in $item.Value) {
                $p = '"{0}"' -f ((Join-Path $root_path $path) -replace "\\$")
                
                if (Test-Path ($p -replace '"')) {
                    # add the folder if it exists
                    $folder_list.Add($p)
                }
                else {
                    # if the folder doesn't exist, log a warning/error
                    $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
                    $warning_message = { Write-Output "[[Backup]] Warning - backup path $p not found." }
                    if ($ignore_error) {
                        & $warning_message | Tee-Object -Append $SuccessLog
                    }
                    else {
                        & $warning_message | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                        $return_value = $false
                    }
                }
            }

        }
        
        if (-not $folder_list) {
            # there are no folders to backup
            $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
            $warning_message = { Write-Output "[[Backup]] Warning - no folders to back up!" }
            if ($ignore_error) {
                & $warning_message | Tee-Object -Append $SuccessLog
            }
            else {
                & $warning_message | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                $return_value = $false
            }
        }
        else {
            # Launch Restic
            & $ResticBin backup $folder_list --tag "$tag" --exclude-file=$LocalExcludeFile 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
            if (-not $?) {
                Write-Output "[[Backup]] Completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
                $return_value = $false
            }
        }

        Write-Output "[[Backup]] End $(Get-Date) [$tag]" | Tee-Object -Append $SuccessLog
    }
    
    Set-Location $starting_location
    Write-Output "[[Backup]] End $(Get-Date)" | Tee-Object -Append $SuccessLog

    return $return_value
}
