# C 第二阶段阶段报告：迁移、权限与库存应用

> 日期：2026-11-05；角色：成员 C（库存、补货、员工权限、审计与总集成）。
> 范围：C 域 2.1 收口后的 2.2 迁移实现与 2.3 库存/认证应用骨架。A/B 的域结论见各自报告；本报告不为全组完整 v1.0 验收背书。

## 1. 实验思路

1. **迁移前先有可复现的基线。** 三域真实 `baseline_*` 文件在同一 `COMPLETED` 批次采集，25 张快照逐值双向比较；摘要只做定位，不作为相等证据。
2. **迁移脚本必须可回滚、可重放。** `11c` 在真实 v0.1 上做外层事务回滚与提交双路径；`run_migration` 缺对象时整事务回滚，不留下半迁移状态。
3. **权限不靠 UI，靠数据库。** 每个员工用自己的 SQL 登录连接，过程按 `USER_NAME()` 解析员工；`Permission`/`RolePermission`/实际 GRANT 由 `13c` 逐项断言。
4. **签名不只数条数。** 三路径验收覆盖「ALTER 后失败/回滚恢复」「重签后成功/回滚恢复」「重签提交 + 普通岗位 229」，并以低权限店长实际调用，而不是只看 `sys.crypt_properties` 计数。
5. **应用层只做输入边界与编排。** 库存页只读四个视图、写入只经既有自持事务过程；不复制账本、状态机或授权判断。

## 2. 过程与产物

### 2.1 迁移与权限

| 文件 | 内容 |
| --- | --- |
| `sql/stage2/capture_baseline.sql` / `baseline_c.sql` | 25 表批次采集入口、C 域 10 表快照；真实 A/B/C 基线 25/0 |
| `sql/stage2/11c_inventory_security_migration.sql` | Permission 拆分；白名单 46→58；RolePermission 52→71；UQ 采购建议；身份上下文；员工角色查询 |
| `sql/stage2/12_permissions.sql` | 19 对新增 GRANT、`cust_app` 条件授权、三个角色同步过程重签、实际授权核对 |
| `sql/stage2/13c_inventory_security_regression.sql` | 15 条 C 域 v1.0 断言（目录/映射/GRANT/cust_app/上下文/UQ/账本/建议/签名/视图/员工角色 229） |
| `sql/stage2/run_migration.sql` / `regression.sql` | 固定顺序入口与域回归汇总；缺 `11b` 回滚、stub 提交、regression 38/0 |
| `result/stage2/c-*` | 实跑证据与 SHA-256（README） |

### 2.2 应用

| 文件 | 内容 |
| --- | --- |
| `app/auth/` | 登录/注销/三结果集身份上下文；服务端内存凭据（8h TTL），cookie 只放随机 token |
| `app/inventory/` | 库存看板、流水、补货创建/调整/提交/审批/驳回、收货、员工角色页 |
| `run.py` | Flask 启动入口；`pyodbc.pooling = False` 进程级兜底 |
| `tests/stage2/auth` / `inventory` | 10 + 12 条 fake-DB 测试；`run-all.ps1` 五套汇总 |
| `sql/stage2/provision_employee.template.ps1` | 员工 SQL 登录/同名用户/EmployeeAccount 映射模板（口令由操作者输入） |

## 3. 本轮核验结果

| 核验 | 实际结果 | 判定方法 |
| --- | --- | --- |
| 真实 25 表采集 | 25 表 / 178 行，**25/0** | A/B/C 真 `baseline_*`；逐表逐值双向 `EXCEPT` |
| `11c` 回滚/提交 | 回滚 **9/0**；提交终态 **58/71** | 真实 v0.1；旧 52 行/名称保真；员工角色映射 |
| `13c` | **15/0** | 临时 B/customer 桩迁移后的 v1.0；店长员工角色正例、cashier 229 |
| `regression` | **38/0** | 13a 10 + 13b 5 + 13b write 8 + 13c 15 |
| 签名三路径 | **3/0** | 真实 v0.1；低权限店长实际调用 + 普通岗位 229 |
| auth | **10/0** | 登录/注销/安全 next/cookie 不含口令/OI-14 适配 |
| inventory | **12/0** | 输入边界、过程参数、视图 SQL、模板、员工角色过程 |
| 既有 app 回归 | common 17/0、master 36/0、orders 20/0；run-all 五套 95/0 | 2026-11-06 C 复核；`run-all.ps1 -Python` 实跑 |

## 4. 决策与边界

- **已关闭**：OI-14（A Common 多结果集，C 已改用 `query_procedure_sets`）、OI-15（员工角色查询，`11c` 58/71）、OI-16（A 修复驱动池，C 2026-11-06 复核）、OI-17（`run-all.ps1` 解释器覆盖，C 修复并实跑 95/0）。
- **仍 open**：OI-18（B 的 `11b` 六查询/`13b` 未到，已公开催办）、OI-10（契约 §1 已冻结，三个顾客过程仍未实现）、OI-05/11 等礼节项。
- **硬阻塞**：B 的真实 `11b_order_migration.sql` 未到（OI-18）；本报告的迁移/回归是**部分迁移 + 临时桩**证据，不宣称完整 2.2。
- **未做**：顾客端页面（待 OI-10）、真实员工 SQL 登录/部署模板执行、真实 B 六查询联调、完整 25 表迁移后的三域证据。
- `cust_app` 三过程由 `12` 条件授权；缺失时 `13c-7` 必须失败，不以空列表冒充成功。

## 5. 下一步

1. B `11b` 到货 → 跑真实 `run_migration` + `regression`，重跑 13b/13c，归档完整证据。
2. A 已修 OI-16（C 已复核关闭）→ 真实登录下验证不同账号交替、异常退出后身份不串。
3. OI-10 回执齐 → 落 `cust_app` 三过程、顾客页与 13c-7/8 真实对象。
4. 收尾更新数据字典、README 与阶段测试报告，清理桩与临时库。
