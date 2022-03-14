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

# Source remaining scripts
$BackupScript = Join-Path $PSScriptRoot "backup.ps1"
$MaintenanceScript = Join-Path $PSScriptRoot "maintenance.ps1"
. $BackupScript
. $MaintenanceScript

function Invoke-Main {
    # random sleep delay
    Start-RandomSleep

    # Start Backup Timer
    if ($UseHealthcheck) {
        Invoke-RestMethod "$hc_url/start" | Out-Null
    }

    Get-BackupState

    $attempt_count = $GlobalRetryAttempts

    while ($attempt_count -gt 0) {
        # setup logfiles
        if (Test-Path $LogPath) {
            Write-Log "Removing old log file: $LogPath"
            Remove-Item $LogPath
        }
        Add-Content -Value "RESTIC SYNOLOGY BACKUP" -Path $LogPath
        
        $internet_available = Invoke-ConnectivityCheck
        if ($internet_available -eq $true) { 
            Invoke-Unlock

            $backup = Invoke-Backup
            $copy = $true
            if (-not $CopyLocalRepo) {
                Write-Log "[[Copy]] Skipping copy."
            }
            else {
                # perform local maintenance before copying to avoid copying snapshots
                # that will immediately be pruned
                Invoke-LocalMaintenance
                $copy = Invoke-Copy
            }

            if ($backup && $copy) {
                if (Get-MaintenanceDue) {
                    Invoke-RemoteMaintenance
                    Invoke-RemoteDatacheck
                    if ($CopyLocalRepo -eq $true) {
                        Invoke-LocalDatacheck
                    }
                }
            }

            if ($Script:ErrorCount -eq 0) {
                # successful with no errors; end
                $total_attempts = $GlobalRetryAttempts - $attempt_count + 1
                Write-Log "Succeeded after $total_attempts attempt(s)"
                $ResticStateSuccessfulBackups++

                $stats = Write-BackupJson
                Write-Log "Total of $($stats.Total) backups ($($stats.Success) successful backups) in past $LogRetentionDays days"
                # Invoke-HistoryCheck $LogPath
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
            $stats = Write-BackupJson -Failure
            $Script:ErrorCount++
            Write-Log "Total of $($stats.Total) backups ($($stats.Success) successful backups)"
        }
        if ($internet_available -eq $true) {
            # Invoke-HistoryCheck $LogPath
            if ($UseHealthcheck) {
                Send-Healthcheck
            }
        }
        if ($attempt_count -gt 0) {
            Start-Sleep (15 * 60)
        }
    }    

    Set-BackupState
}

Invoke-Main
exit $Script:ErrorCount
