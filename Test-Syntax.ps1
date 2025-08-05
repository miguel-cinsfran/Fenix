param(
    [string]$FilePath
)

if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
    Write-Host "[ERROR] File not found: $FilePath" -ForegroundColor Red
    exit 1
}

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$errors)

if ($errors.Count -eq 0) {
    Write-Host "[SUCCESS] Syntax is valid for: $FilePath" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[ERROR] Syntax errors found in: $FilePath" -ForegroundColor Red
    $errors | ForEach-Object {
        Write-Host " - $($_.Message) (Line: $($_.Extent.StartLineNumber))"
    }
    exit 1
}
