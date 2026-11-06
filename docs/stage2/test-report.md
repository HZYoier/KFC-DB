# 第二阶段测试报告（C 侧）

> 日期：2026-11-05；环境：`.\SQLEXPRESS`（SQL Server 2025 Express，compat 170）；Python `py_env3.11`（Python 3.11.15，Flask 3.1.3，pyodbc 5.3.0）。
> 范围：C 域迁移/权限/审计、C 侧应用与跨域 Common 回归。A/B 的完整域测试见各自报告；本报告不把临时桩结果当作完整 v1.0 验收。

## 1. SQL 与迁移

| 测试 | 实际结果 | 证据 |
| --- | --- | --- |
| 真实 25 表基线采集（A/B/C 真文件） | 25 表 / 178 行；逐表逐值 **25/0** | `result/stage2/c-real-capture-2026-11-03.txt` |
| `11c` 58/71 外层事务回滚 | **9/0**；回滚后 v0.1（52 行/旧列/旧 CHECK） | `result/stage2/c-11c-employee-roles-2026-11-05.txt` |
| 部分迁移提交（11a + 11b 桩 + 11c + 12） | 58/71、`cust_app` 三 GRANT、三签名；提交成功 | 同上 |
| `13a` / `13b` baseline / `13b` write | **10/0** / **5/0** / **8/8** | 同上 |
| `13c` | **15/0**（目录/映射/GRANT/cust_app/上下文/UQ/账本/建议/签名/视图/员工角色 229） | 同上 |
| `regression.sql` | **38/0**（13a 10 + 13b 5 + 13b 8 + 13c 15） | 同上 |
| 签名三路径低权限 | **3/0**（ALTER 后回滚 / 重签后回滚 / 重签提交 + 普通岗位 229） | `result/stage2/c-signature-three-paths-2026-11-03.txt` |

## 2. 应用层

| 套件 | 结果 | 说明 |
| --- | --- | --- |
| `tests/stage2/common`（A） | **17/0** | 多结果集顺序/空集占位/nextset 异常 + OI-16 驱动池/身份隔离；C 已改用 `query_procedure_sets` |
| `tests/stage2/auth`（C） | **10/0** | 登录/注销/安全 next/cookie 不含口令/身份失效检测 |
| `tests/stage2/inventory`（C） | **12/0** | 输入边界/参数定型/视图 SQL/模板/员工角色正反入口 |
| `tests/stage2/master`（A） | **36/0** | 既有主数据域回归 |
| `tests/stage2/orders`（B） | **20/0** | B 的 Common 适配后回归（需 `--sql-server`） |

`tests/stage2/run-all.ps1` 已更新为五套（`files=5`），增加 `-Python`/`$env:KFC_DB_PYTHON` 覆盖；2026-11-06 以 `powershell -NoProfile -File ... -Python D:\Miniconda\envs\py_env3.11\python.exe` 实跑五套 **95/0**，证据 `result/stage2/c-oi17-runall-2026-11-06.txt`。

## 3. 未覆盖与边界

- **B 的真实 `11b_order_migration.sql` 未到**：完整 2.2 迁移、真实 B 六查询与三域完整对账未做；`13b`/`13c` 的部分结果基于临时桩。
- **OI-16 已修**：A 在 `open_connection` 每次连接前关闭驱动池，C 复核 common 17/0、auth 10/0、inventory 12/0；真实不同账号交替仍需在员工 SQL 登录部署后联合验证。
- **OI-10 顾客三过程未实现**：`cust_app` 三过程条件授权，顾客页与 13c-7/8 真实对象未联调。
- **真实员工登录/部署模板未执行**：`provision_employee.template.ps1` 仅通过 PowerShell 语法解析；无真实 SQL 登录环境证据。
- `KFC_DB` 在测试后删除；复现需先 `run_all.sql`，再做采集/迁移/测试。
