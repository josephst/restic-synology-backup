#!/usr/bin/pwsh

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
# TODO: put these in a configuration directory
$SecretsScript = Join-Path "/etc/backup" "secrets.ps1"

# backup configuration variables
$ConfigScript = Join-Path "/etc/backup" "config.ps1"

# =========== end configuration =========== #

# globals for state storage
$Script:ResticStateRepositoryInitialized = $null
$Script:ResticStateLastMaintenance = $null
$Script:ResticStateLastDeepMaintenance = $null
$Script:ResticStateMaintenanceCounter = $null

# globals for error counting
$ErrorCount = 0

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
    Param($BackupLog)

    $locks = & $ResticBin list locks --no-lock -q 3>&1 2>> $BackupLog
    if ($locks.Length -gt 0) {
        # unlock the repository (assumes this machine is the only one that will ever use it)
        & $ResticBin unlock 3>&1 2>> $BackupLog | Tee-Object -Append $BackupLog
        Write-Output "[[Unlock]] Repository was locked. Unlocking. Past script failure?" | Tee-Object -Append $BackupLog
        Start-Sleep 60
    }
}

function Invoke-Maintenance {
    Param($BackupLog)
    
    # skip maintenance if disabled
    if ($SnapshotMaintenanceEnabled -eq $false) {
        Write-Output "[[Maintenance]] Skipped - maintenance disabled" | Tee-Object -Append $BackupLog
    }

    # skip maintenance if it's been done recently
    if (($null -ne $ResticStateLastMaintenance) -and ($null -ne $ResticStateMaintenanceCounter)) {
        $Script:ResticStateMaintenanceCounter += 1
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if (($delta.Days -lt $SnapshotMaintenanceDays) -and ($ResticStateMaintenanceCounter -lt $SnapshotMaintenanceInterval)) {
            Write-Output "[[Maintenance]] Skipped - last maintenance $ResticStateLastMaintenance ($($delta.Days) days, $ResticStateMaintenanceCounter backups ago)" | Tee-Object -Append $BackupLog
            return
        }
    }

    Write-Output "[[Maintenance]] Start $(Get-Date)" | Tee-Object -Append $BackupLog
    $maintenance_success = $true
    Start-Sleep 5

    # forget snapshots based upon the retention policy
    Write-Output "[[Maintenance]] Start forgetting..." | Tee-Object -Append $BackupLog
    & $ResticBin forget $SnapshotRetentionPolicy *>&1 | Tee-Object -Append $BackupLog
    if (-not $?) {
        Write-Error "[ERROR] [[Maintenance]] Forget operation completed with errors" *>&1 | Tee-Object -Append $BackupLog
        $ErrorCount++
        $maintenance_success = $false
    }

    # prune (remove) data from the backup step. Running this separate from `forget` because
    #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
    Write-Output "[[Maintenance]] Start pruning..." | Tee-Object -Append $BackupLog
    & $ResticBin prune $SnapshotPrunePolicy *>&1 | Tee-Object -Append $BackupLog
    if (-not $?) {
        Write-Error "[ERROR] [[Maintenance]] Prune operation completed with errors" *>&1 `
        | Tee-Object -Append $BackupLog
        $ErrorCount++
        $maintenance_success = $false
    }

    # perform quick data check (full data checks are done by datacheck.ps1)
    Write-Output "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)" | Tee-Object -Append $BackupLog
    # Write-Output "[[Maintenance]] Run `datacheck.ps1` for a full data check" | Tee-Object -Append $BackupLog

    & $ResticBin check *>&1 | Tee-Object -Append $BackupLog
    if (-not $?) {
        Write-Error "[ERROR] [[Maintenance]] It looks like the data check failed! Possible data corruption?" *>&1 `
            $ErrorCount++
        | Tee-Object -Append $BackupLog
    }

    Write-Output "[[Maintenance]] End $(Get-Date)" | Tee-Object -Append $BackupLog
    
    if ($maintenance_success -eq $true) {
        $Script:ResticStateLastMaintenance = Get-Date
        $Script:ResticStateMaintenanceCounter = 0
    }
}

# TODO: find a way to use history check again (need a way to store success/fail of previous backups)
# function Invoke-HistoryCheck {
#     Param($BackupLog)
#     Write-Output "[[History]] Backup success rate: $ResticStateSuccessfulBackups / $ResticStateTotalBackups ($(($ResticStateSuccessfulBackups / $ResticStateTotalBackups).ToString("P")))" | Tee-Object -Append $BackupLog
# }

function Invoke-Backup {
    Param($BackupLog)

    Write-Output "[[Backup]] Start $(Get-Date)" | Tee-Object -Append $BackupLog
    $return_value = $true
    ForEach ($folder in $BackupSources.GetEnumerator()) {
        # BackupSources is an array of folder names
        Write-Output "[[Backup]] Start $(Get-Date) [$folder]" | Tee-Object -Append $BackupLog

        if (Test-Path $folder) {
            # Launch Restic
            Write-Output "[[Backup]] Backing up $folder" | Tee-Object -Append $BackupLog
            & $ResticBin backup $folder --tag "$folder" --exclude-file=$LocalExcludeFile --one-file-system *>&1 `
            | Tee-Object -Append $BackupLog
            if (-not $?) {
                Write-Error "[ERROR] [[Backup]] Completed with errors" *>&1 | Tee-Object -Append $BackupLog
                $ErrorCount++
                $return_value = $false
            }
        }
        else {
            $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
            $warning_message = "[[Backup]] Warning - backup path $folder not found."
            if ($ignore_error) {
                Write-Output $warning_message | Tee-Object -Append $BackupLog
            }
            else {
                Write-Error $warning_message *>&1 | Tee-Object -Append $BackupLog
                $ErrorCount++
                $return_value = $false
            }
        }

        Write-Output "[[Backup]] End $(Get-Date) [$folder]" | Tee-Object -Append $BackupLog
    }
    
    Write-Output "[[Backup]] End $(Get-Date)" | Tee-Object -Append $BackupLog

    return $return_value
}

# copy an existing restic backup to a new location
# new location should have same chunker params as existing location
# to ensure deduplication. See https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories
function Invoke-Copy {
    Param($BackupLog)

    Write-Output "[[Copy]] Start $(Get-Date)" | Tee-Object -Append $BackupLog
    $return_value = $true

    # swap passwords around
    $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD

    try {
        # test to make sure local repo exists before copying from it
        & $ResticBin snapshots -r $Env:RESTIC_REPOSITORY2
        if (-not $?) {
            Write-Error "[ERROR] [[Copy]] Could not find a local repository to copy from" *>&1 `
            | Tee-Object -Append $BackupLog
            $ErrorCount++
            $return_value = $false
        }
        else {
            # copy from local repo (repo2) to remote repo
            & $ResticBin -r $Env:RESTIC_REPOSITORY2 copy --repo2 $env:RESTIC_REPOSITORY
            $return_value = $?
        }
    }
    finally {
        # cleanup and swap passwords back
        $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
        Write-Output "[[Copy]] End $(Get-Date)" | Tee-Object -Append $BackupLog
    }

    return $return_value
}

function Invoke-ConnectivityCheck {
    Param($BackupLog)
    
    if ($InternetTestAttempts -le 0) {
        Write-Output "[[Internet]] Internet connectivity check disabled. Skipping." | Tee-Object -Append $BackupLog    
        return $true
    }

    # skip the internet connectivity check for local repos
    if (Test-Path $env:RESTIC_REPOSITORY) {
        Write-Output "[[Internet]] Local repository. Skipping internet connectivity check." | Tee-Object -Append $BackupLog    
        return $true
    }

    $repository_host = ''

    # use generic internet service for non-specific repo types (e.g. swift:, rclone:, etc. )
    if (($env:RESTIC_REPOSITORY -match "^swift:") -or 
        ($env:RESTIC_REPOSITORY -match "^rclone:")) {
        $repository_host = "cloudflare.com"
    }
    elseif ($env:RESTIC_REPOSITORY -match "^b2:") {
        $repository_host = "api.backblazeb2.com"
    }
    elseif ($env:RESTIC_REPOSITORY -match "^azure:") {
        $repository_host = "azure.microsoft.com"
    }
    elseif ($env:RESTIC_REPOSITORY -match "^gs:") {
        $repository_host = "storage.googleapis.com"
    }
    else {
        # parse connection string for hostname
        # Uri parser doesn't handle leading connection type info (s3:, sftp:, rest:)
        $connection_string = $env:RESTIC_REPOSITORY -replace "^s3:" -replace "^sftp:" -replace "^rest:"
        if (-not ($connection_string -match "://")) {
            # Uri parser expects to have a protocol. Add 'https://' to make it parse correctly.
            $connection_string = "https://" + $connection_string
        }
        $repository_host = ([System.Uri]$connection_string).DnsSafeHost
    }

    if ([string]::IsNullOrEmpty($repository_host)) {
        Write-Error "[ERROR] [[Internet]] Repository string could not be parsed." *>&1 | Tee-Object -Append $BackupLog
        $ErrorCount++
        return $false
    }

    # test for internet connectivity
    $connections = 0
    $sleep_count = $InternetTestAttempts
    while ($true) {
        $connections = Get-NetRoute | Where-Object DestinationPrefix -eq '0.0.0.0/0' | Get-NetIPInterface | Where-Object ConnectionState -eq 'Connected' | Measure-Object | ForEach-Object { $_.Count }
        if ($sleep_count -le 0) {
            Write-Error "[ERROR] [[Internet]] Connection to repository ($repository_host) could not be established." *>&1 `
            | Tee-Object -Append $BackupLog
            $ErrorCount++
            return $false
        }
        if (($null -eq $connections) -or ($connections -eq 0)) {
            Write-Output "[[Internet]] Waiting for internet connectivity... $sleep_count" `
            | Tee-Object -Append $BackupLog
            Start-Sleep 30
        }
        elseif (!(Test-Connection -ComputerName $repository_host -Quiet)) {
            Write-Output "[[Internet]] Waiting for connection to repository ($repository_host)... $sleep_count" `
            | Tee-Object -Append $BackupLog
            Start-Sleep 30
        }
        else {
            return $true
        }
        $sleep_count--
    }
}

function Send-Healthcheck {
    Param($BackupLog)

    # $status = "SUCCESS"
    # $success_after_failure = $false
    $body = ""
    # if (($null -ne $SuccessLog) -and (Test-Path $SuccessLog) -and (Get-Item $SuccessLog).Length -gt 0) {
    #     $body = $(Get-Content -Raw $SuccessLog)
    #     # if previous run contained an error, send the success email confirming that the error has been resolved
    #     # (i.e. get previous error log, if it's not empty, trigger the send of the success-after-failure email)
    #     $previous_error_log = Get-ChildItem $LogPath -Filter '*err.txt' | Sort-Object -Descending LastWriteTime | Select-Object -Skip 1 | Select-Object -First 1
    #     if (($null -ne $previous_error_log) -and ($previous_error_log.Length -gt 0)) {
    #         $success_after_failure = $true
    #     }
    # }

    # else {
    # $body = "Critical Error! Restic backup log is empty or missing. Check log file path."
    # $status = "ERROR"
    # }
    # $attachments = @{}

    if (($null -eq $BackupLog) -or (-not (Test-Path $BackupLog)) -or (Get-Item $BackupLog).Length -eq 0) {
        # Restic backup log is missing or empty
        # $status = "ERROR"
        Write-Error "[ERROR] Restic backup log is missing or empty" *>&1 | Tee-Object -Append $BackupLog
        $ErrorCount++
    }
    else {
        $body = $(Get-Content -Raw $BackupLog)
    }

    Invoke-RestMethod -Method Post -Uri "$hc_url/$ErrorCount" -Body $body | Out-File -Append $BackupLog

    if (-not $?) {
        Write-Error "[ERROR] [[Email]] Sending Healthcheck ping completed with errors" *>&1 | Tee-Object -Append $BackupLog
        $ErrorCount++
    }
}

function Invoke-Main {

    . $SecretsScript
    . $ConfigScript

    # Start Backup Timer
    if ($UseHealthcheck) {
        Invoke-RestMethod "$hc_url/start" | Out-Null
    }

    Get-BackupState

    if (!(Test-Path $LogPath)) {
        Write-Error "[ERROR] [[Backup]] Log file directory $LogPath does not exist. Exiting."
        $ErrorCount++
        exit
    }

    $attempt_count = $GlobalRetryAttempts

    while ($attempt_count -gt 0) {
        # setup logfiles
        $backup_log = Join-Path $LogPath ("backup.log")
        if (Test-Path $backup_log) {
            Write-Output "Removing old log file: $backup_log"
            Remove-Item $backup_log
        }
        
        $internet_available = Invoke-ConnectivityCheck $backup_log
        if ($internet_available -eq $true) { 
            Invoke-Unlock $backup_log
            $backup_output = Invoke-Backup $backup_log
            $copy_output = @($true)
            Write-Output $backup_output # write output to console
            if ($CopyLocalRepo) {
                $copy_output = Invoke-Copy $backup_log
                Write-Output $copy_output # write output to console
            }
            if ($backup_output[-1] && $copy_output[-1]) {
                # last value returned by each function is success (true) or failure (false)
                Invoke-Maintenance $backup_log
            }

            if ($ErrorCount -eq 0) {
                # successful with no errors; end
                $total_attempts = $GlobalRetryAttempts - $attempt_count + 1
                Write-Output "Succeeded after $total_attempts attempt(s)" | Tee-Object -Append $backup_log
                $ResticStateSuccessfulBackups++
                # Invoke-HistoryCheck $backup_log
                if ($UseHealthcheck) {
                    Send-Healthcheck $backup_log
                }
                break;
            }
        }
        
        $attempt_count--
        if ($attempt_count -gt 0) {
            Write-Output "[[Retry]] Sleeping for 15 min and then retrying..." | Tee-Object -Append $backup_log
        }
        else {
            Write-Error "[ERROR] [[Retry]] Retry limit has been reached. No more attempts to backup will be made." *>&1 `
            | Tee-Object -Append $backup_log
            $ErrorCount++
        }
        if ($internet_available -eq $true) {
            # Invoke-HistoryCheck $backup_log
            if ($UseHealthcheck) {
                Send-Healthcheck $backup_log
            }
        }
        if ($attempt_count -gt 0) {
            Start-Sleep (15 * 60)
        }
    }    

    Set-BackupState

    # cleanup older log files
    # Get-ChildItem $LogPath | Where-Object { $_.CreationTime -lt $(Get-Date).AddDays(-$LogRetentionDays) } | Remove-Item

    return $ErrorCount
}

Invoke-Main
