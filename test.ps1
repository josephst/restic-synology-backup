function New-Foobar {
    Write-Output "Hello"
    Write-Output "World"
    return $false
}

$results = (New-Foobar)[-1]
Write-Output $results
