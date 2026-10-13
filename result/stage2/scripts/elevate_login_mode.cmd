@echo off
set LOG=D:\DBLab\_kfcdb_tmp\elevate_login_mode.log
echo BEGIN %DATE% %TIME% > "%LOG%"
reg add "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.SQLEXPRESS\MSSQLServer" /v LoginMode /t REG_DWORD /d 2 /f >> "%LOG%" 2>&1
net stop MSSQL$SQLEXPRESS >> "%LOG%" 2>&1
net start MSSQL$SQLEXPRESS >> "%LOG%" 2>&1
reg query "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL17.SQLEXPRESS\MSSQLServer" /v LoginMode >> "%LOG%" 2>&1
echo DONE >> "%LOG%"
