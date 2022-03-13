#!/usr/bin/pwsh

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
# TODO: put these in a configuration directory

# backup configuration variables
$ConfigScript = Join-Path "/etc/backup" "config.ps1"

# =========== end configuration =========== #

# Load configuration
. $ConfigScript

# globals for state storage
$Script:ResticStateRepositoryInitialized = $null
$Script:ResticStateLastMaintenance = $null
$Script:ResticStateLastDeepMaintenance = $null
$Script:ResticStateMaintenanceCounter = $null

# local (ie when maintenance was last run on the backups stored on the NAS)
$Script:ResticStateLocalLastMaintenance = $null
$Script:ResticStateLocalLastDeepMaintenance = $null
$Script:ResticStateLocalMaintenanceCounter = $null

# globals for error counting
[int]$Script:ErrorCount = 0

function Start-RandomSleep {
    $Delay = [int]$Env:RANDOM_DELAY ?? 0
    $SleepDelay = 0
    if ($Delay -gt 0) {
        $SleepDelay = Get-Random -Minimum 0 -Maximum $Delay
    }
    Start-Sleep -Seconds $SleepDelay
}

function Switch-RepositoryPasswords {
    $env:RESTIC_PASSWORD, $env:RESTIC_PASSWORD2 = $env:RESTIC_PASSWORD2, $env:RESTIC_PASSWORD
}

function Get-BackupState {
    if (Test-Path $StateFile) {
        Import-Clixml $StateFile | ForEach-Object { Set-Variable -Scope Script $_.Name $_.Value }
    }
}
function Set-BackupState {
    Get-Variable ResticState* | Export-Clixml $StateFile
}

function Write-Log {
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline)] $LogMessage,
        [switch]$IsErrorMessage
    )

    begin {
        $timeStamp = Get-Date -Format 'HH:mm:ss'
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
            "[$timeStamp] [ERROR] $message" | Tee-Object -FilePath $LogPath -Append | Write-Error
        }
        else {
            "[$timeStamp] $message" | Tee-Object -FilePath $LogPath -Append | Write-Verbose -Verbose
        }
    }
}

function Write-BackupJson {
    [CmdletBinding()]
    param (
        [switch]
        $Failure
    )
    process {
        $backup_results_path = Join-Path "/var/backup" "results.json"
        $previous_backups = @()
        if (Test-Path $backup_results_path) {
            $previous_backups = Get-Content $backup_results_path | Out-String | ConvertFrom-Json
        }

        # add new data to array
        $recent_backup_data = [pscustomobject]@{
            Date    = $(Get-Date)
            Success = !$Failure
        }

        # limit to 30 days ($LogRetentionDays) of backup history
        $previous_backups = @($previous_backups) + @($recent_backup_data)
        $previous_backups = $previous_backups.Where({ $_.Date -gt $(Get-Date).AddDays(-$LogRetentionDays) })

        # save
        $previous_backups | ConvertTo-Json -AsArray | Out-File $backup_results_path

        $SuccessCount = $($previous_backups.Where{ $_.Success -eq $true }).Count
        $TotalCount = $previous_backups.Count

        # return success stats
        $stats = [PSCustomObject]@{
            Success = $SuccessCount
            Total   = $TotalCount
        }

        return $stats
    }
}

function Convert-FriendlyBytes {
    # https://stackoverflow.com/a/24617034 by mjolinor & Peter Mortensen
    param(
        [Parameter(Mandatory)][int] $ByteCount
    )
    switch -Regex ([math]::truncate([math]::log($ByteCount, 1024))) {

        '^0' { "$ByteCount Bytes" }
    
        '^1' { "{0:n2} KB" -f ($ByteCount / 1KB) }
    
        '^2' { "{0:n2} MB" -f ($ByteCount / 1MB) }
    
        '^3' { "{0:n2} GB" -f ($ByteCount / 1GB) }
    
        '^4' { "{0:n2} TB" -f ($ByteCount / 1TB) }
    
        Default { "{0:n2} PB" -f ($ByteCount / 1pb) }
    }
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
    $body = ""

    if (($null -eq $LogPath) -or (-not (Test-Path $LogPath)) -or (Get-Item $LogPath).Length -eq 0) {
        # Restic backup log is missing or empty
        # $status = "ERROR"
        $body = "[[Healthcheck]] Restic backup log is missing or empty!"
        Write-Log $body -IsErrorMessage
        $ErrorCount++
    }
    else {
        $body = $(Get-Content -Raw $LogPath)
    }

    Invoke-RestMethod -Method Post -Uri "$hc_url/$ErrorCount" -Body $body | Out-Null

    if (-not $?) {
        Write-Log "[[Healthcheck]] Sending Healthcheck ping completed with errors" -IsErrorMessage
        $ErrorCount++
    }
}
