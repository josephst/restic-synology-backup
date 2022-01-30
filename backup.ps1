#!/usr/bin/pwsh

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
# TODO: put these in a configuration directory
$SecretsScript = Join-Path "/etc/backup" "secrets.ps1"

# backup configuration variables
$ConfigScript = Join-Path "/etc/backup" "config.ps1"

# =========== end configuration =========== #

# Load configuration
. $SecretsScript
. $ConfigScript


# globals for state storage
$Script:ResticStateRepositoryInitialized = $null
$Script:ResticStateLastMaintenance = $null
$Script:ResticStateLastDeepMaintenance = $null
$Script:ResticStateMaintenanceCounter = $null

# globals for error counting
[int]$ErrorCount = 0

# Misc other globals
$backup_log = $LogPath

function Write-Log {
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline)] $LogMessage,
        [switch]$IsErrorMessage
    )

    begin {
        $timeStamp = Get-Date -Format 'hh:mm:ss'
    }

    process {
        $message = ""
        if ($LogMessage -is [System.Management.Automation.ErrorRecord]) {
            $IsErrorMessage = $true
            $message = $LogMessage.ToString()
        }
        else {
            $message = $LogMessage
        }
        if ($IsErrorMessage) {
            "[$timeStamp] [ERROR] $message" | Tee-Object -FilePath $backup_log -Append | Write-Error
        }
        else {
            # Write-Verbose -Verbose so we can actually see what's being printed
            "[$timeStamp] $message" | Tee-Object -FilePath $backup_log -Append | Write-Verbose -Verbose
        }
    }
}

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
    $locks = & $ResticBin list locks --no-lock -q 3>&1
    if (!$?) {
        Write-Log "[[Unlock]] Unable to get a list of locks" -IsErrorMessage
    }
    if ($locks.Length -gt 0) {
        # unlock the repository (assumes this machine is the only one that will ever use it)
        & $ResticBin unlock *>&1 | Write-Log
        Write-Log "[[Unlock]] Repository was locked. Unlocking. Past script failure?"
        Start-Sleep 60
    }
}

function Invoke-Maintenance {
    
    # skip maintenance if disabled
    if ($SnapshotMaintenanceEnabled -eq $false) {
        Write-Log "[[Maintenance]] Skipped - maintenance disabled"
    }

    # skip maintenance if it's been done recently
    if (($null -ne $ResticStateLastMaintenance) -and ($null -ne $ResticStateMaintenanceCounter)) {
        $Script:ResticStateMaintenanceCounter += 1
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if (($delta.Days -lt $SnapshotMaintenanceDays) -and ($ResticStateMaintenanceCounter -lt $SnapshotMaintenanceInterval)) {
            Write-Log "[[Maintenance]] Skipped - last maintenance $ResticStateLastMaintenance ($($delta.Days) days, $ResticStateMaintenanceCounter backups ago)"
            return
        }
    }

    Write-Log "[[Maintenance]] Start $(Get-Date)"
    $maintenance_success = $true
    Start-Sleep 5

    # forget snapshots based upon the retention policy
    Write-Log "[[Maintenance]] Start forgetting..." 
    & $ResticBin forget $SnapshotRetentionPolicy *>&1 | Write-Log
    if (-not $?) {
        Write-Log "[[Maintenance]] Forget operation completed with errors" -IsErrorMessage
        $ErrorCount++
        $maintenance_success = $false
    }

    # prune (remove) data from the backup step. Running this separate from `forget` because
    #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
    Write-Log "[[Maintenance]] Start pruning..."
    & $ResticBin prune $SnapshotPrunePolicy *>&1 | Write-Log
    $pruneSuccess = $?
    if (-not $pruneSuccess) {
        Write-Log "[[Maintenance]] Prune operation completed with errors" -IsErrorMessage
        $ErrorCount++
        $maintenance_success = $false
    }

    # perform quick data check (full data checks are done by datacheck.ps1)
    Write-Log "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)"
    # Write-Output "[[Maintenance]] Run `datacheck.ps1` for a full data check" | Tee-Object -Append $BackupLog

    & $ResticBin check *>&1 | Write-Log
    if (-not $?) {
        Write-Log "[[Maintenance]] It looks like the data check failed! Possible data corruption?" -IsErrorMessage
        $ErrorCount++
    }

    Write-Log "[[Maintenance]] End $(Get-Date)"
    
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
    Write-Log "[[Backup]] Start $(Get-Date)"
    $return_value = $true
    ForEach ($folder in $BackupSources.GetEnumerator()) {
        # BackupSources is an array of folder names
        Write-Log "[[Backup]] Start $(Get-Date) [$folder]"

        if (Test-Path $folder) {
            # Launch Restic
            Write-Log "[[Backup]] Backing up $folder"
            & $ResticBin backup $folder --tag "$folder" --exclude-file=$LocalExcludeFile --one-file-system *>&1 | Write-Log
            if (-not $?) {
                Write-Log "[[Backup]] Completed with errors" -IsErrorMessage
                $ErrorCount++
                $return_value = $false
            }
        }
        else {
            $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
            $warning_message = "[[Backup]] Warning - backup path $folder not found."
            if ($ignore_error) {
                Write-Log $warning_message
            }
            else {
                Write-Log $warning_message -IsErrorMessage
                $ErrorCount++
                $return_value = $false
            }
        }

        Write-Log "[[Backup]] End $(Get-Date) [$folder]"
    }
    
    Write-Log "[[Backup]] End $(Get-Date)"

    return $return_value
}

# copy an existing restic backup to a new location
# new location should have same chunker params as existing location
# to ensure deduplication. See https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories
function Invoke-Copy {
    if (-not $CopyLocalRepo) {
        Write-Log "[[Copy]] Skipping copy."
        return $true
    }
    else {
        Write-Log "[[Copy]] Start $(Get-Date)"
        $return_value = $true
    
        # swap passwords around
        $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
    
        try {
            # test to make sure local repo exists before copying from it
            & $ResticBin snapshots -r $Env:RESTIC_REPOSITORY2 | Out-Null
            if (-not $?) {
                Write-Log "[[Copy]] Could not find a local repository to copy from" -IsErrorMessage
                $ErrorCount++
                $return_value = $false
            }
            else {
                # copy from local repo (repo2) to remote repo
                & $ResticBin -r $Env:RESTIC_REPOSITORY2 copy --repo2 $env:RESTIC_REPOSITORY *>&1 | Write-Log
                if (-not $?) {
                    $return_value = $false
                    Write-Log "[[Copy]] Copying completed with errors" -IsErrorMessage
                }
            }
        }
        finally {
            # cleanup and swap passwords back
            $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
            Write-Log "[[Copy]] End $(Get-Date)"
        }
    
        return $return_value
    }
}

function Invoke-ConnectivityCheck {
    
    if ($InternetTestAttempts -le 0) {
        Write-Log "[[Internet]] Internet connectivity check disabled. Skipping." 
        return $true
    }

    # skip the internet connectivity check for local repos
    if (Test-Path $env:RESTIC_REPOSITORY) {
        Write-Log "[[Internet]] Local repository. Skipping internet connectivity check."    
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
        Write-Log "[[Internet]] Repository string could not be parsed." -IsErrorMessage
        $ErrorCount++
        return $false
    }

    # test for internet connectivity
    $sleep_count = $InternetTestAttempts
    while ($true) {
        if ($sleep_count -le 0) {
            Write-Log "[ERROR] [[Internet]] Connection to repository ($repository_host) could not be established." -IsErrorMessage
            $ErrorCount++
            return $false
        }
        elseif (!(Test-Connection -ComputerName $repository_host -Quiet)) {
            Write-Log "[[Internet]] Waiting for connection to repository ($repository_host)... ($sleep_count s)"
            Start-Sleep 30
        }
        else {
            return $true
        }
        $sleep_count--
    }
}

function Send-Healthcheck {

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

    if (($null -eq $backup_log) -or (-not (Test-Path $backup_log)) -or (Get-Item $backup_log).Length -eq 0) {
        # Restic backup log is missing or empty
        # $status = "ERROR"
        $body = "[[Healthcheck]] Restic backup log is missing or empty!"
        Write-Log $body -IsErrorMessage
        $ErrorCount++
    }
    else {
        $body = $(Get-Content -Raw $backup_log)
    }

    Invoke-RestMethod -Method Post -Uri "$hc_url/$ErrorCount" -Body $body | Out-Null

    if (-not $?) {
        Write-Log "[[Healthcheck]] Sending Healthcheck ping completed with errors" -IsErrorMessage
        $ErrorCount++
    }
}

function Invoke-Main {

    # Start Backup Timer
    if ($UseHealthcheck) {
        Invoke-RestMethod "$hc_url/start" | Out-Null
    }

    Get-BackupState

    $attempt_count = $GlobalRetryAttempts

    while ($attempt_count -gt 0) {
        # setup logfiles
        if (Test-Path $backup_log) {
            Write-Log "Removing old log file: $backup_log"
            Remove-Item $backup_log
        }
        
        $internet_available = Invoke-ConnectivityCheck
        if ($internet_available -eq $true) { 
            Invoke-Unlock
            $backup = Invoke-Backup
            $copy = Invoke-Copy
            if ($backup && $copy) {
                Invoke-Maintenance
            }

            if ($ErrorCount -eq 0) {
                # successful with no errors; end
                $total_attempts = $GlobalRetryAttempts - $attempt_count + 1
                Write-Log "Succeeded after $total_attempts attempt(s)"
                $ResticStateSuccessfulBackups++
                # Invoke-HistoryCheck $backup_log
                if ($UseHealthcheck) {
                    Send-Healthcheck
                }
                break;
            }
        }
        
        $attempt_count--
        if ($attempt_count -gt 0) {
            Write-Log "[[Retry]] Sleeping for 15 min and then retrying..."
        }
        else {
            Write-Log "[[Retry]] Retry limit has been reached. No more attempts to backup will be made." -IsErrorMessage
            $ErrorCount++
        }
        if ($internet_available -eq $true) {
            # Invoke-HistoryCheck $backup_log
            if ($UseHealthcheck) {
                Send-Healthcheck
            }
        }
        if ($attempt_count -gt 0) {
            Start-Sleep (15 * 60)
        }
    }    

    Set-BackupState

    return $ErrorCount
}

Invoke-Main
