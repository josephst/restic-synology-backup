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
        # make a new repository (repo2, with data from setB)
        & $ResticBin init
        & $ResticBin backup -H setB "/dataB"
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

    # restore a file that was copied
    # mimics a restore from the `restic copy` command
    $out = & $ResticBin dump -H setB latest "/dataB/example.txt"
    if ($out -eq $(Get-Content "/dataB/example.txt")) {
        Write-Output "Copy and restore successful"
    } else {
        Write-Error "Unsuccessful copy and restore"
    }

    # restore a file that was backed up
    # mimics a restore from the `restic backup` command
    $out = & $ResticBin dump -H $(hostname) latest "/data/foo.txt"
    if ($out -eq $(Get-Content "/data/foo.txt")) {
        Write-Output "Backup and restore successful"
    } else {
        Write-Error "Unsuccessful backup and restore"
    }

    # test file restore
    & $ResticBin restore latest -H $(hostname) --include "/data" --target /tmp/restore
    if ($(Get-FileHash "/tmp/restore/data/foo.txt").Hash -eq (Get-FileHash "/data/foo.txt").Hash) {
        Write-Output "File restore: hashes match"
    } else {
        Write-Error "File restore: hashes do NOT match"
    }
}

function Remove-Backup {
    . $SecretsScript
    . $ConfigScript

    $repos = @("$env:RESTIC_REPOSITORY")
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
# New-LocalRepo
Test-Backup
Test-Restore
