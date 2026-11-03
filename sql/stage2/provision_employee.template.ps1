<#
.SYNOPSIS
    为 KFC-DB 创建“员工 SQL 登录 + 同名数据库用户”的部署模板（C）。

.DESCRIPTION
    默认身份路径：每个员工一个 SQL Server 登录，登录名映射到同名数据库用户；
    EmployeeAccount.database_user_name 保存 USER_NAME() 返回值。密码只在本次
    操作的内存中出现，不写入脚本、配置、日志或仓库。首次店长可用
    -BootstrapStoreManager 加入 role_store_manager 作为受控启动引导。

    先决条件：实例已启用混合模式（SQL Server 身份验证）；KFC_DB、08、09c/11c 已部署。
    真实密码由操作者执行时输入；不要修改本模板后再提交任何密码。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File sql/stage2/provision_employee.template.ps1 `
        -SqlInstance '.\SQLEXPRESS' -LoginName 'zhangsan' `
        -EmployeeName '张三' -JobCode 'STORE_MANAGER' -BootstrapStoreManager
#>
[CmdletBinding()]
param(
    [string]$SqlInstance = '.\SQLEXPRESS',
    [string]$Database = 'KFC_DB',

    [Parameter(Mandatory = $true)]
    [string]$LoginName,

    [string]$DatabaseUserName = '',
    [Parameter(Mandatory = $true)]
    [string]$EmployeeName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('STORE_MANAGER', 'SHIFT_MANAGER', 'CASHIER', 'CHEF', 'PACKER', 'WAITER', 'RIDER')]
    [string]$JobCode,

    [switch]$BootstrapStoreManager,
    [switch]$SkipPasswordPolicy
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DatabaseUserName)) {
    $DatabaseUserName = $LoginName
}

function Quote-Identifier([string]$name) {
    return '[' + $name.Replace(']', ']]') + ']'
}

function Quote-Literal([string]$value) {
    return "N'" + $value.Replace("'", "''") + "'"
}

function New-SqlConnection([string]$connectionString) {
    return New-Object System.Data.SqlClient.SqlConnection $connectionString
}

function Invoke-SqlNonQuery([string]$connectionString, [string]$sql) {
    $connection = New-SqlConnection $connectionString
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
    $connection = New-SqlConnection $connectionString
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
$user = Quote-Identifier $DatabaseUserName
$passwordLiteral = Quote-Literal $password
$loginLiteral = Quote-Literal $LoginName
$userLiteral = Quote-Literal $DatabaseUserName
$nameLiteral = Quote-Literal $EmployeeName
$jobLiteral = Quote-Literal $JobCode
$policy = if ($SkipPasswordPolicy) { 'OFF' } else { 'ON' }

$windows = "Server=$SqlInstance;Database=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
$windowsMaster = "Server=$SqlInstance;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"

Write-Host "检查登录 $LoginName ..."
$loginExists = Invoke-SqlScalar $windowsMaster "SELECT CASE WHEN SUSER_ID($loginLiteral) IS NULL THEN 0 ELSE 1 END;"
if ($loginExists -eq 0) {
    Invoke-SqlNonQuery $windowsMaster "CREATE LOGIN $login WITH PASSWORD=$passwordLiteral, CHECK_POLICY=$policy;"
    Write-Host "已创建登录 $LoginName。"
}
else {
    Write-Host "登录 $LoginName 已存在；不覆盖现有口令，继续用本次输入的口令验证。"
}

Write-Host "检查数据库用户 $DatabaseUserName ..."
$userExists = Invoke-SqlScalar $windows "SELECT CASE WHEN DATABASE_PRINCIPAL_ID($userLiteral) IS NULL THEN 0 ELSE 1 END;"
if ($userExists -eq 0) {
    Invoke-SqlNonQuery $windows "CREATE USER $user FOR LOGIN $login;"
    Write-Host "已创建数据库用户 $DatabaseUserName。"
}
else {
    $mapped = Invoke-SqlScalar $windows @"
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM sys.database_principals AS dp
    JOIN sys.server_principals AS sp ON sp.sid = dp.sid
    WHERE dp.name = $userLiteral AND sp.name = $loginLiteral
) THEN 1 ELSE 0 END;
"@
    if ($mapped -eq 0) {
        Invoke-SqlNonQuery $windows "ALTER USER $user WITH LOGIN = $login;"
        Write-Host "已将数据库用户 $DatabaseUserName 映射到登录 $LoginName。"
    }
}

$employeeId = Invoke-SqlScalar $windows "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = $userLiteral;"
if ($null -eq $employeeId) {
    Invoke-SqlNonQuery $windows @"
INSERT INTO dbo.EmployeeAccount (database_user_name, login_name, employee_name, job_code, [status])
VALUES ($userLiteral, $loginLiteral, $nameLiteral, $jobLiteral, 'ACTIVE');
"@
    $employeeId = Invoke-SqlScalar $windows "SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = $userLiteral;"
    Write-Host "已创建 EmployeeAccount（$DatabaseUserName / $EmployeeName / $JobCode）。"
}
else {
    Write-Host "EmployeeAccount 已存在（employee_id=$employeeId）；不覆盖现有档案。"
}

if ($BootstrapStoreManager) {
    $roleExists = Invoke-SqlScalar $windows "SELECT CASE WHEN DATABASE_PRINCIPAL_ID(N'role_store_manager') IS NULL THEN 0 ELSE 1 END;"
    if ($roleExists -ne 1) {
        throw 'role_store_manager 不存在；请先部署 08_roles_permissions.sql。'
    }
    $member = Invoke-SqlScalar $windows @"
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.database_role_members AS drm
    JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
    WHERE r.name = N'role_store_manager' AND m.name = $userLiteral
) THEN 1 ELSE 0 END;
"@
    if ($member -ne 1) {
        Invoke-SqlNonQuery $windows "ALTER ROLE role_store_manager ADD MEMBER $user;"
        Write-Host "已加入 role_store_manager（仅首次启动引导）。"
    }
}

$employeeConnection = "Server=$SqlInstance;Database=$Database;User ID=$LoginName;Password=$password;Encrypt=True;TrustServerCertificate=True;"
$who = Invoke-SqlScalar $employeeConnection "SELECT USER_NAME();"
if ($who -ne $DatabaseUserName) {
    throw "员工连接返回 USER_NAME()=$who，期望 $DatabaseUserName。"
}

$contextExists = Invoke-SqlScalar $windows "SELECT CASE WHEN OBJECT_ID(N'dbo.sp_get_current_employee_context', N'P') IS NULL THEN 0 ELSE 1 END;"
if ($contextExists -eq 1) {
    $contextWho = Invoke-SqlScalar $employeeConnection "EXEC dbo.sp_get_current_employee_context;"
    if ($contextWho -ne [long]$employeeId) {
        throw "身份上下文返回的 employee_id=$contextWho 与 EmployeeAccount=$employeeId 不一致。"
    }
    Write-Host "身份上下文校验通过（employee_id=$employeeId）。"
}

Write-Host "RESULT: provisioned login=$LoginName database_user=$DatabaseUserName employee_id=$employeeId"
