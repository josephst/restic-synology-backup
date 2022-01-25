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
    if ($null -eq $env:RESTIC_REPOSITORY2) {
        & $ResticBin init
    } else {
        # if there's a second repo we'll be copying from,
        # use its chunker params for data dedup
        & $ResticBin init --copy-chunker-params
    }
    
    $out = $?
    
    if (-not $out) {
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
    Start-Sleep 5

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

function Invoke-HistoryCheck {
    Param($SuccessLog, $ErrorLog)
    $logs = Get-ChildItem $LogPath -Filter '*err.txt' | ForEach-Object { $_.Length -gt 0 }
    $logs_with_success = ($logs | Where-Object { ($_ -eq $false) }).Count
    if ($logs.Count -gt 0) {
        Write-Output "[[History]] Backup success rate: $logs_with_success / $($logs.Count) ($(($logs_with_success / $logs.Count).tostring("P")))" | Tee-Object -Append $SuccessLog
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
            Write-Output "[[Backup]] Backing up $folder_list" | Tee-Object -Append $SuccessLog
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

# copy an existing restic backup to a new location
# new location should have same chunker params as existing location
# to ensure deduplication. See https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories
function Invoke-Copy {
    Param($SuccessLog, $ErrorLog)

    Write-Output "[[Copy]] Start $(Get-Date)" | Tee-Object -Append $SuccessLog
    $return_value = $true

    # swap passwords around
    $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD

    try {
        # test to make sure local repo exists before copying from it
        & $ResticBin snapshots -r $Env:RESTIC_REPOSITORY2
        if (-not $?) {
            Write-Output "[[Copy]] Could not find a local repository to copy from" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
            $return_value = $false
        }
        else {
            # copy from local repo (repo2) to remote repo
            & $ResticBin -r $Env:RESTIC_REPOSITORY2 copy --repo2 $env:RESTIC_REPOSITORY
        }
    }
    finally {
        # cleanup and swap passwords back
        $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
        Write-Output "[[Copy]] End $(Get-Date)" | Tee-Object -Append $SuccessLog
    }

    return $return_value
}

function Invoke-ConnectivityCheck {
    Param($SuccessLog, $ErrorLog)
    
    if ($InternetTestAttempts -le 0) {
        Write-Output "[[Internet]] Internet connectivity check disabled. Skipping." | Tee-Object -Append $SuccessLog    
        return $true
    }

    # skip the internet connectivity check for local repos
    if (Test-Path $env:RESTIC_REPOSITORY) {
        Write-Output "[[Internet]] Local repository. Skipping internet connectivity check." | Tee-Object -Append $SuccessLog    
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
        Write-Output "[[Internet]] Repository string could not be parsed." | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
        return $false
    }

    # test for internet connectivity
    $connections = 0
    $sleep_count = $InternetTestAttempts
    while ($true) {
        $connections = Get-NetRoute | Where-Object DestinationPrefix -eq '0.0.0.0/0' | Get-NetIPInterface | Where-Object ConnectionState -eq 'Connected' | Measure-Object | ForEach-Object { $_.Count }
        if ($sleep_count -le 0) {
            Write-Output "[[Internet]] Connection to repository ($repository_host) could not be established." | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
            return $false
        }
        if (($null -eq $connections) -or ($connections -eq 0)) {
            Write-Output "[[Internet]] Waiting for internet connectivity... $sleep_count" | Tee-Object -Append $SuccessLog
            Start-Sleep 30
        }
        elseif (!(Test-Connection -ComputerName $repository_host -Quiet)) {
            Write-Output "[[Internet]] Waiting for connection to repository ($repository_host)... $sleep_count" | Tee-Object -Append $SuccessLog
            Start-Sleep 30
        }
        else {
            return $true
        }
        $sleep_count--
    }
}

function Send-Healthcheck {
    Param($SuccessLog, $ErrorLog)

    $status = "SUCCESS"
    $success_after_failure = $false
    $body = ""
    if (($null -ne $SuccessLog) -and (Test-Path $SuccessLog) -and (Get-Item $SuccessLog).Length -gt 0) {
        $body = $(Get-Content -Raw $SuccessLog)
        # if previous run contained an error, send the success email confirming that the error has been resolved
        # (i.e. get previous error log, if it's not empty, trigger the send of the success-after-failure email)
        $previous_error_log = Get-ChildItem $LogPath -Filter '*err.txt' | Sort-Object -Descending LastWriteTime | Select-Object -Skip 1 | Select-Object -First 1
        if (($null -ne $previous_error_log) -and ($previous_error_log.Length -gt 0)) {
            $success_after_failure = $true
        }
    }

    else {
        $body = "Critical Error! Restic backup log is empty or missing. Check log file path."
        $status = "ERROR"
    }
    # $attachments = @{}
    if (($null -ne $ErrorLog) -and (Test-Path $ErrorLog) -and (Get-Item $ErrorLog).Length -gt 0) {
        # $attachments = @{Attachments = $ErrorLog}
        $status = "ERROR"
    }
    if ((($status -eq "SUCCESS") -and ($UseHealthcheck -ne $false)) -or ((($status -eq "ERROR") -or $success_after_failure) -and ($UseHealthcheck -ne $false))) {
        # $subject = "$env:COMPUTERNAME Restic Backup Report [$status]"

        # create a temporary error log to log errors; can't write to the same file that Send-MailMessage is reading
        $temp_error_log = $ErrorLog + "_temp"

        # Send-MailMessage @ResticEmailConfig -From $ResticEmailFrom -To $ResticEmailTo -Credential $credentials -Subject $subject -Body $body @attachments 3>&1 2>> $temp_error_log
        # Send success ping to healthchecks (NOTE: unique URL for each backed-up device)
        $error_flag = $(If ($status -eq "ERROR") { "fail" } Else { "0" })
        Invoke-RestMethod -Method Post -Uri "$hc_url/$error_flag" -Body $body | Out-Null

        if (-not $?) {
            Write-Output "[[Email]] Sending email completed with errors" | Tee-Object -Append $temp_error_log | Tee-Object -Append $SuccessLog
        }

        # join error logs and remove the temporary
        if (Test-Path $temp_error_log) {
            Get-Content $temp_error_log | Add-Content $ErrorLog
            Remove-Item $temp_error_log
        }
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
        Write-Error "[[Backup]] Log file directory $LogPath does not exist. Exiting."
        exit
    }

    $error_count = 0;
    $attempt_count = $GlobalRetryAttempts

    while ($attempt_count -gt 0) {
        # setup logfiles
        $timestamp = Get-Date -Format FileDateTime
        $success_log = Join-Path $LogPath ($timestamp + ".log.txt")
        $error_log = Join-Path $LogPath ($timestamp + ".err.txt")
        
        $internet_available = Invoke-ConnectivityCheck $success_log $error_log
        if ($internet_available -eq $true) { 
            Invoke-Unlock $success_log $error_log
            $backup_success = Invoke-Backup $success_log $error_log
            $copy_success = $true
            if ($CopyLocalRepo) {
                $copy_success = Invoke-Copy $success_log $error_log
            }
            if ($backup_success && $copy_success) {
                Invoke-Maintenance $success_log $error_log
            }

            if (!(Test-Path $error_log) -or ((Get-Item $error_log).Length -eq 0)) {
                # successful with no errors; end
                $total_attempts = $GlobalRetryAttempts - $attempt_count + 1
                Write-Output "Succeeded after $total_attempts attempt(s)" | Tee-Object -Append $success_log
                Invoke-HistoryCheck $success_log $error_log
                if ($UseHealthcheck) {
                    Send-Healthcheck $success_log $error_log
                }
                break;
            }
        }

        Write-Output "[[General]] Errors found. Log: $error_log" | Tee-Object -Append $success_log | Tee-Object -Append $error_log
        $error_count++
        
        $attempt_count--
        if ($attempt_count -gt 0) {
            Write-Output "[[Retry]] Sleeping for 15 min and then retrying..." | Tee-Object -Append $success_log
        }
        else {
            Write-Output "[[Retry]] Retry limit has been reached. No more attempts to backup will be made." | Tee-Object -Append $success_log
        }
        if ($internet_available -eq $true) {
            Invoke-HistoryCheck $success_log $error_log
            if ($UseHealthcheck) {
                Send-Healthcheck $success_log $error_log
            }
        }
        if ($attempt_count -gt 0) {
            Start-Sleep (15 * 60)
        }
    }    

    Set-BackupState

    # cleanup older log files
    Get-ChildItem $LogPath | Where-Object { $_.CreationTime -lt $(Get-Date).AddDays(-$LogRetentionDays) } | Remove-Item

    return $error_count
}
