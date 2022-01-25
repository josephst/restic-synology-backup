# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
$SecretsScript = Join-Path $PSScriptRoot "secrets.ps1"

# backup configuration variables
$ConfigScript = Join-Path $PSScriptRoot "config.ps1"

# =========== end configuration =========== #
function Test-Backup {
    param (
    )

    . ./backup.ps1
    . $SecretsScript
    . $ConfigScript

    # Create new repo for testing
    & $ResticBin snapshots | Out-Null
    $status = $?
    if (-not $status) {
        New-Repo
    }

    # Run backup
    Invoke-BackupProcess $hc_url
}

function Clear-Backup {
    ./backup.ps1

    . $SecretsScript
    . $ConfigScript

    Remove-Item -Recurse -Force $env:RESTIC_REPOSITORY/*
    Remove-Item -Recurse -Force logs/*
}

Test-Backup
