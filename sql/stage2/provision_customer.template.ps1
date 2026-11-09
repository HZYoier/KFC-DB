<#
.SYNOPSIS
    为 KFC-DB 的共享顾客账户 `cust_app` 创建/映射一个 SQL 登录（C）。

.DESCRIPTION
    `12_permissions.sql` 以 WITHOUT LOGIN 创建数据库用户 `cust_app`，并只授予
    `sp_customer_register` / `sp_customer_place_order` / `sp_customer_list_orders`
    的 EXECUTE。本模板只做服务器登录和登录→用户映射，不授予任何额外权限。

    口令只在本次操作内存中出现，不写入脚本、配置、日志或仓库。先决条件：
    混合模式实例、已部署 v1.0（含 12_permissions），操作者具备 CREATE LOGIN 权限。
    执行后把登录名/口令写入本机 `.env` 的 KFC_CUST_DB_LOGIN / KFC_CUST_DB_PASSWORD。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File sql/stage2/provision_customer.template.ps1 `
        -SqlInstance '.\SQLEXPRESS' -LoginName 'cust_app_login'
#>
[CmdletBinding()]
param(
    [string]$SqlInstance = '.\SQLEXPRESS',
    [string]$Database = 'KFC_DB',
    [string]$LoginName = 'cust_app_login'
)

$ErrorActionPreference = 'Stop'

function Quote-Identifier([string]$name) {
    return '[' + $name.Replace(']', ']]') + ']'
}

function Quote-Literal([string]$value) {
    return "N'" + $value.Replace("'", "''") + "'"
}

function Invoke-SqlNonQuery([string]$connectionString, [string]$sql) {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Close()
    }
}

function Invoke-SqlScalar([string]$connectionString, [string]$sql) {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Close()
    }
}

$secure = Read-Host -AsSecureString ("SQL login password for {0}" -f $LoginName)
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrEmpty($password)) {
    throw '密码不能为空。'
}

$login = Quote-Identifier $LoginName
$loginLiteral = Quote-Literal $LoginName
$passwordLiteral = Quote-Literal $password
$windowsMaster = "Server=$SqlInstance;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
$windowsDb = "Server=$SqlInstance;Database=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
$customerConnection = "Server=$SqlInstance;Database=$Database;User ID=$LoginName;Password=$password;Encrypt=True;TrustServerCertificate=True;"

$loginExists = Invoke-SqlScalar $windowsMaster "SELECT CASE WHEN SUSER_ID($loginLiteral) IS NULL THEN 0 ELSE 1 END;"
if ($loginExists -eq 0) {
    Invoke-SqlNonQuery $windowsMaster "CREATE LOGIN $login WITH PASSWORD=$passwordLiteral, CHECK_POLICY=ON;"
    Write-Host "已创建登录 $LoginName。"
}
else {
    Write-Host "登录 $LoginName 已存在；不覆盖现有口令，继续用本次输入的口令验证。"
}

$userExists = Invoke-SqlScalar $windowsDb "SELECT CASE WHEN DATABASE_PRINCIPAL_ID(N'cust_app') IS NULL THEN 0 ELSE 1 END;"
if ($userExists -ne 1) {
    throw '数据库用户 cust_app 不存在；请先部署 v1.0 的 12_permissions.sql。'
}

$mapped = Invoke-SqlScalar $windowsDb @"
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.database_principals AS dp
    JOIN sys.server_principals AS sp ON sp.sid = dp.sid
    WHERE dp.name = N'cust_app' AND sp.name = $loginLiteral
) THEN 1 ELSE 0 END;
"@
if ($mapped -ne 1) {
    Invoke-SqlNonQuery $windowsDb "ALTER USER cust_app WITH LOGIN = $login;"
    Write-Host "已将 cust_app 映射到登录 $LoginName。"
}
else {
    Write-Host "cust_app 已映射到登录 $LoginName。"
}

$who = Invoke-SqlScalar $customerConnection "SELECT USER_NAME();"
if ($who -ne 'cust_app') {
    throw "顾客连接返回 USER_NAME()=$who，期望 cust_app。"
}

$procNames = @('sp_customer_register', 'sp_customer_place_order', 'sp_customer_list_orders')
foreach ($proc in $procNames) {
    $granted = Invoke-SqlScalar $customerConnection "SELECT CASE WHEN HAS_PERMS_BY_NAME(N'dbo.$proc', N'OBJECT', N'EXECUTE') = 1 THEN 1 ELSE 0 END;"
    if ($granted -ne 1) {
        throw "cust_app 缺少 $proc 的 EXECUTE；请检查 12_permissions.sql。"
    }
}
$denied = Invoke-SqlScalar $customerConnection "SELECT CASE WHEN HAS_PERMS_BY_NAME(N'dbo.SalesOrder', N'OBJECT', N'SELECT') = 1 THEN 1 ELSE 0 END;"
if ($denied -ne 0) {
    throw 'cust_app 不应拥有 SalesOrder 的 SELECT；请检查授权。'
}

Write-Host 'RESULT: provisioned customer login; USER_NAME()=cust_app; three EXECUTE grants verified.'
Write-Host '本机 .env 需要设置 KFC_CUST_DB_LOGIN / KFC_CUST_DB_PASSWORD；不要把口令写入仓库。'
