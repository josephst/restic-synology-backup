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

function Invoke-Backup {
    Write-Log "[[Backup]] Start $(Get-Date)"
    $return_value = $true
    ForEach ($folder in $BackupSources.GetEnumerator()) {
        # BackupSources is an array of folder names
        Write-Log "[[Backup]] Start $(Get-Date) [$folder]"

        if (Test-Path $folder) {
            # Launch Restic
            Write-Log "[[Backup]] Backing up $folder"
            $backupJson = & $ResticBin backup $folder --json --tag "$folder" --exclude-file=$LocalExcludeFile | ConvertFrom-Json
            $backupSuccess = $?
            if (-not $backupSuccess) {
                $errorMessage = $backupJson.Where{ $_.message_type -match "error" } | Format-List | Out-String
                Write-Log "[[Backup]] $errorMessage" -IsErrorMessage
                Write-Log "[[Backup]] Completed with errors" -IsErrorMessage
                $ErrorCount++
                $return_value = $false
            }
            else {
                $backupSummary = $backupJson[-1] # last message is summary message
                $summaryText = "[[Backup]] Backed up $($backupSummary.files_new) new files " +
                "($(Convert-FriendlyBytes $backupSummary.data_added)) in $($backupSummary.total_duration) " +
                "seconds."
                Write-Log $summaryText
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
        Write-Log "[[Copy]] Copying from $Env:RESTIC_REPOSITORY2 to $Env:RESTIC_REPOSITORY"
        $return_value = $true
    
        try {
            # swap passwords around, 
            $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
            
            # test to make sure local repo exists before copying from it
            & $ResticBin snapshots -r $Env:RESTIC_REPOSITORY2 | Out-Null
            if (-not $?) {
                Write-Log "[[Copy]] Could not find a local repository to copy from" -IsErrorMessage
                $ErrorCount++
                $return_value = $false
            }
            else {
                # copy from local repo (repo2) to remote repo
                # since passwords are swapped, primary password is now for repo2 (the local repo)
                # and secondary password is for repo1  (the repo being copied to)
                $copyOutput = & $ResticBin -r $Env:RESTIC_REPOSITORY2 copy --repo2 $env:RESTIC_REPOSITORY
                $copySuccess = $?
                if (-not $copySuccess) {
                    $return_value = $false
                    Write-Log "[[Copy]] Copying completed with errors" -IsErrorMessage
                }
                else {
                    $copyGroups = $copyOutput -split '(?:\r?\n){2,}'
                    Write-Log "[[Copy]] Copied $($copyGroups.Count) snapshots"
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
