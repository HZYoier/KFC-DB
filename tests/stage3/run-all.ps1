# Run all three Stage 3 acceptance suites against a disposable KFC_DB at v1.1.
# Stage 2 regression has its own entry point.
param(
    [string]$SqlServer = '.\SQLEXPRESS',
    [string]$Sqlcmd = 'sqlcmd',
    [string]$CondaEnv = 'py_env3.11',
    [string]$Python = $env:KFC_DB_PYTHON
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Invoke-AcceptanceSuite {
    param(
        [string]$Name,
        [string]$Program,
        [string[]]$Arguments,
        [string]$Expected
    )

    Write-Host "=== $Name ==="
    # unittest writes its progress to stderr. Keep it visible without treating it
    # as a failed invocation in Windows PowerShell.
    $ErrorActionPreference = 'Continue'
    $output = & $Program @Arguments 2>&1
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) {
        Write-Host "FAIL: $Name (exit $code)"
        exit $code
    }
    if ($output -cnotcontains $Expected) {
        Write-Host "FAIL: $Name (expected $Expected)"
        exit 1
    }
}

Push-Location -LiteralPath $root
try {
    $sqlcmdProgram = (Get-Command $Sqlcmd -CommandType Application).Path
    if ($Python) {
        $pythonProgram = (Get-Command $Python -CommandType Application).Path
        $pythonPrefix = @()
    } else {
        $pythonProgram = 'conda'
        $null = Get-Command $pythonProgram
        $pythonPrefix = @('run', '-n', $CondaEnv, 'python')
    }

    $verify = Join-Path $root 'sql/stage3/verify_stage3.sql'
    Invoke-AcceptanceSuite -Name 'stage3 SQL' -Program $sqlcmdProgram `
        -Arguments @('-S', $SqlServer, '-E', '-C', '-f', '65001', '-b', '-I', '-i', $verify) `
        -Expected 'RESULT: stage3-regression suites=10 pass=123 fail=0 (28a 52 + 28b 8 + 28c 63)'
    Invoke-AcceptanceSuite -Name 'A reports app' -Program $pythonProgram `
        -Arguments ($pythonPrefix + 'tests/stage3/a_app/run_a_app_tests.py') `
        -Expected 'RESULT: pass=9 fail=0 skip=0 total=9'
    Invoke-AcceptanceSuite -Name 'C inventory app' -Program $pythonProgram `
        -Arguments ($pythonPrefix + 'tests/stage3/c_app/run_c_app_tests.py') `
        -Expected 'RESULT: pass=8 fail=0 skip=0 total=8'
    Write-Host 'RESULT: run-all files=3 failed=0'
} finally {
    Pop-Location
}
