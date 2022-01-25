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
    Invoke-Main
}

function New-LocalRepo {
    # create a local repo (Repo2) to test copying
    . ./backup.ps1
    . $SecretsScript
    . $ConfigScript

    $repo1 = @{
        Repo     = $env:RESTIC_REPOSITORY;
        Password = $env:RESTIC_PASSWORD;
    }
    $repo2 = @{
        Repo     = $env:RESTIC_REPOSITORY2;
        Password = $env:RESTIC_PASSWORD2;
    }

    $env:RESTIC_REPOSITORY = $repo2.Repo
    $env:RESTIC_PASSWORD = $repo2.Password

    $env:RESTIC_REPOSITORY2 = $null
    $env:RESTIC_PASSWORD2 = $null

    try {
        # make a new repository (repo2)
        & $ResticBin init
        & $ResticBin backup "./dataForBackup/setA"
    }
    finally {
        $env:RESTIC_REPOSITORY = $repo1.Repo
        $env:RESTIC_PASSWORD = $repo1.Password
        $env:RESTIC_REPOSITORY2 = $repo2.Repo
        $env:RESTIC_PASSWORD2 = $repo2.Password
    }
}

function Test-Restore {
    . $SecretsScript
    . $ConfigScript

    & $ResticBin 
}

function Remove-Backup {
    . $SecretsScript
    . $ConfigScript

    $repos = @("$env:RESTIC_REPOSITORY", "$env:RESTIC_REPOSITORY2")
    foreach ($repo in $repos) {
        $msg = "Do you want to remove all data in $repo [y/n]?"
        $response = Read-Host -Prompt $msg
        if ($response -eq 'y') {
            Remove-Item -Recurse -Force "$repo/*"
        }
    }
    Remove-Item -Recurse -Force logs/*
}

Remove-Backup
New-LocalRepo
Test-Backup
Test-Restore
