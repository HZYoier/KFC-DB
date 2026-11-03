# KFC-DB 2.3 测试汇总入口（C）
# 用法（仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File tests/stage2/run-all.ps1
#   powershell ... -File tests/stage2/run-all.ps1 -SqlServer '.\SQLEXPRESS' -CondaEnv py_env3.11
# 每个子入口自己校验分母并打印 RESULT；任一非零退出即停止。
param(
    [string]$SqlServer = '.\SQLEXPRESS',
    [string]$CondaEnv = 'py_env3.11'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root

function Invoke-PythonSuite {
    param([string]$Name, [string[]]$Arguments)
    Write-Host "=== $Name ==="
    & conda run -n $CondaEnv python @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: $Name (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}

Invoke-PythonSuite 'auth' @('tests/stage2/auth/run_auth_tests.py')
Invoke-PythonSuite 'master' @('tests/stage2/master/run_master_tests.py')
Invoke-PythonSuite 'orders' @('tests/stage2/orders/run_tests.py', '--sql-server', $SqlServer)
Invoke-PythonSuite 'inventory' @('tests/stage2/inventory/run_inventory_tests.py')

Write-Host 'RESULT: run-all files=4 failed=0'
exit 0
