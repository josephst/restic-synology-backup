# =========== start configuration =========== # 


# backup configuration variables
$ConfigScript = Join-Path "/etc/backup" "config.ps1"


# =========== end configuration =========== #
function Test-Backup {
    # Create new repo for testing
    & $ResticBin snapshots *>&1 | Out-Null
    $exists = $?
    if (!$exists) {
        New-Repo
    }

    # Make sure log file exists
    New-Item -Force -Path $LogPath

    # Run backup
    . (Join-Path $PSScriptRoot "../src/script/main.ps1")
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
    
    if (-not $?) {
        Write-Error "[ERROR] [[Init]] Failed to init the repository: $($Env:RESTIC_REPOSITORY)"
        exit 1
    }
}

function New-LocalRepo {
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
        $exists = restic snapshots | Out-Null
        if ($exists) {
            Write-Output "Local/ secondary repo already exists at $repo2.Repo. Skipping repo creation"
            return
        } else {
            & $ResticBin init
            & $ResticBin backup -H setB "/dataB"
        }
    }
    finally {
        $env:RESTIC_REPOSITORY = $repo1.Repo
        $env:RESTIC_PASSWORD = $repo1.Password
        $env:RESTIC_REPOSITORY2 = $repo2.Repo
        $env:RESTIC_PASSWORD2 = $repo2.Password
    }
}

function Test-Restore {
    # restore a file that was copied
    # mimics a restore from the `restic copy` command
    $out = & $ResticBin dump -H setB latest "/dataB/example.txt"
    if ($out -eq $(Get-Content "/dataB/example.txt")) {
        Write-Output "Copy and restore successful"
    } else {
        Write-Error "[ERROR] Unsuccessful copy and restore"
    }

    # restore a file that was backed up
    # mimics a restore from the `restic backup` command
    $out = & $ResticBin dump -H $(hostname) latest "/data/foo.txt"
    if ($out -eq $(Get-Content "/data/foo.txt")) {
        Write-Output "Backup and restore successful"
    } else {
        Write-Error "[ERROR] Unsuccessful backup and restore"
    }

    # test file restore
    & $ResticBin restore latest -H $(hostname) --include "/data" --target /tmp/restore
    if ($(Get-FileHash "/tmp/restore/data/foo.txt").Hash -eq (Get-FileHash "/data/foo.txt").Hash) {
        Write-Output "File restore: hashes match"
    } else {
        Write-Error "[ERROR] File restore: hashes do NOT match"
    }
}

function Remove-Backup {
    $repos = @("$env:RESTIC_REPOSITORY")
    foreach ($repo in $repos) {
        $msg = "Do you want to remove all data in $repo [y/n]?"
        $response = Read-Host -Prompt $msg
        if ($response -eq 'y') {
            Remove-Item -Recurse -Force "$repo/*"
        } else {
            Write-Error "[ERROR] Not removing data, exiting."
            exit 1
        }
    }
    Remove-Item -Recurse -Force test/logDir/*
}

# run tests
. $ConfigScript

# override $LogPath from the config script
$LogPath = Join-Path $PSScriptRoot "logDir/backup-test.log" # for testing, put log file in this folder
$Env:RANDOM_DELAY = 0 # no delays for testing

Remove-Backup
# New-LocalRepo
Test-Backup
Test-Restore
