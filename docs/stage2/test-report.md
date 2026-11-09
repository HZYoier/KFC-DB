# 第二阶段测试报告（C 侧）

> 日期：2026-11-05；2026-11-06/09 增补真实 11b 迁移、顾客页与最终回归。环境：`.\SQLEXPRESS`（SQL Server 2025 Express，compat 170）；Python `py_env3.11`（Python 3.11.15，Flask 3.1.3，pyodbc 5.3.0）。
> 范围：C 域迁移/权限/审计、C 侧应用与跨域 Common 回归。A/B 的完整域测试见各自报告；本报告不把临时桩结果当作完整 v1.0 验收。

## 1. SQL 与迁移

| 测试 | 实际结果 | 证据 |
| --- | --- | --- |
| 真实 25 表基线采集（A/B/C 真文件） | 25 表 / 178 行；逐表逐值 **25/0** | `result/stage2/c-real-capture-2026-11-03.txt` |
| 真实 `run_migration`（A 11a + B 11b + C 11c/12） | 提交 v1.0；**15 个过程 / 3 个 `cust_app` GRANT / 58 码 / 71 行** | `result/stage2/c-real-migration-2026-11-09.txt` |
| `13a` / `13b` baseline / `13b` write | **10/0** / **5/0** / **8/8** | 真实迁移后的 `regression` |
| `13c` | **15/0**（目录/映射/GRANT/cust_app/上下文/UQ/账本/建议/签名/视图/员工角色 229） | 同上 |
| `regression.sql` | **38/0**（13a 10 + 13b 5 + 13b 8 + 13c 15） | 同上 |
| `cust_app` 三过程 | **3/0**（`EXECUTE AS USER='cust_app'` 实调 register/place/list；事务回滚） | `result/stage2/c-customer-custapp-2026-11-09.txt` |
| 签名三路径低权限 | **3/0**（ALTER 后回滚 / 重签后回滚 / 重签提交 + 普通岗位 229） | `result/stage2/c-signature-three-paths-2026-11-03.txt` |
| `11c` 回滚/提交 | 回滚 **9/0**；提交终态 **58/71** | `result/stage2/c-11c-employee-roles-2026-11-05.txt` |

## 2. 应用层

| 套件 | 结果 | 说明 |
| --- | --- | --- |
| `tests/stage2/common`（A） | **18/0** | 多结果集顺序/空集占位/nextset 异常 + OI-16 驱动池/身份隔离 + `530xx` 错误映射 |
| `tests/stage2/auth`（C） | **10/0** | 登录/注销/安全 next/cookie 不含口令/身份失效检测 |
| `tests/stage2/inventory`（C） | **12/0** | 输入边界/参数定型/视图 SQL/模板/员工角色正反入口 |
| `tests/stage2/customer`（C） | **10/0** | `/customer` 公开页、建档/下单/查单输入边界、`cust_app` 参数定型、失败不连库 |
| `tests/stage2/master`（A） | **36/0** | 既有主数据域回归 |
| `tests/stage2/orders`（B） | **20/0** | B 的 Common 适配后回归（需 `--sql-server`） |

`tests/stage2/run-all.ps1` 已更新为六套（`files=6`），支持 `-Python`/`$env:KFC_DB_PYTHON`；2026-11-09 以 `powershell -NoProfile -File ... -Python D:\Miniconda\envs\py_env3.11\python.exe` 实跑六套 **106/0**（common 18 + auth 10 + master 36 + orders 20 + inventory 12 + customer 10），`RESULT: run-all files=6 failed=0`，证据 `result/stage2/c-runall-customer-2026-11-09.txt`。

## 3. 未覆盖与边界

- **顾客真实 HTTP 登录未做**：`/customer` 的 fake DAO 测试与 `EXECUTE AS USER='cust_app'` 三过程测试通过；真实 SQL 登录映射需操作者执行 `provision_customer.template.ps1` 并设置本机 `.env` 的 `KFC_CUST_DB_LOGIN`/`KFC_CUST_DB_PASSWORD`，再用浏览器走通建档→下单→取餐码查单。 顾客页当前输入商品 ID/数量；本轮没有对顾客开放的商品目录过程，商品 ID 需向店员确认。
- **真实员工 SQL 登录/员工模板未执行**：`provision_employee.template.ps1` 仅通过 PowerShell 语法解析；不影响本报告的 SQL/应用 fake-DB 结论，但联合登录验收仍未做。
- **B 的验收记录独立**：B 的 11b 行为/并发/退款等由 `result/stage2/b-order-acceptance-final.md` 负责；C 只复核了真实迁移、13c、cust_app 三过程与六套应用测试，不代签 B 的页面/并发结论。
- **OI-20 非阻塞**：历史审计脚本硬编码仓库根，C/B 各属主下次处理；不影响已归档结论。
- `KFC_DB` 在测试后删除；复现需先 `sql/stage1/run_all.sql`，再做采集/迁移/测试。
