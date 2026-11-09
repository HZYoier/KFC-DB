# C 第二阶段阶段报告：迁移、权限、库存与顾客应用

> 日期：2026-11-05；2026-11-09 完成真实 11b 迁移、顾客页与最终回归。角色：成员 C（库存、补货、员工权限、审计与总集成）。
> 范围：C 域 2.1 收口后的 2.2 迁移实现与 2.3 库存/认证/顾客应用。A/B 的域结论见各自报告；本报告不为全组完整 v1.0 验收背书。

## 1. 实验思路

1. **迁移前先有可复现的基线。** 三域真实 `baseline_*` 文件在同一 `COMPLETED` 批次采集，25 张快照逐值双向比较；摘要只做定位，不作为相等证据。
2. **迁移脚本必须可回滚、可重放。** `11c` 在真实 v0.1 上做外层事务提交与回滚双路径；`run_migration` 缺对象时整事务回滚，不留下半迁移状态。
3. **权限不靠 UI，靠数据库。** 每个员工用自己的 SQL 登录连接，过程按 `USER_NAME()` 解析员工；`Permission`/`RolePermission`/实际 GRANT 由 `13c` 逐项断言。
4. **签名不只数条数。** 三路径验收覆盖「ALTER 后失败/回滚恢复」「重签后成功/回滚恢复」「重签提交 + 普通岗位 229」，并以低权限店长实际调用，而不是只看 `sys.crypt_properties` 计数。
5. **应用层只做输入边界与编排。** 库存页只读四个视图、写入只经既有自持事务过程；顾客页只经 `cust_app` 调三个顾客过程，不读基表、不借用员工会话。

## 2. 过程与产物

### 2.1 迁移与权限

| 文件 | 内容 |
| --- | --- |
| `sql/stage2/capture_baseline.sql` / `baseline_c.sql` | 25 表批次采集入口、C 域 10 表快照；真实 A/B/C 基线 25/0 |
| `sql/stage2/11c_inventory_security_migration.sql` | Permission 拆分；白名单 46→58；RolePermission 52→71；UQ 采购建议；身份上下文；员工角色查询 |
| `sql/stage2/12_permissions.sql` | 19 对新增 GRANT、`cust_app` 三个顾客过程 GRANT、三个角色同步过程重签、实际授权核对 |
| `sql/stage2/13c_inventory_security_regression.sql` | 15 条 C 域 v1.0 断言（目录/映射/GRANT/cust_app/上下文/UQ/账本/建议/签名/视图/员工角色 229） |
| `sql/stage2/run_migration.sql` / `regression.sql` | 固定顺序入口（11a→11b→11c→12）与域回归汇总；53513 当前要求 **15 个过程** |
| `result/stage2/c-*` | 实跑证据与 SHA-256（README） |

### 2.2 应用

| 文件 | 内容 |
| --- | --- |
| `app/auth/` | 员工登录/注销/三结果集身份上下文；服务端内存凭据（8h TTL），cookie 只放随机 token |
| `app/auth/customer.py` / `customer_dao.py` / `customer_service.py` | `/customer` 公开建档/下单/查单；只用 `cust_app` 调 `sp_customer_register`、`sp_customer_place_order`、`sp_customer_list_orders`，不读基表。顾客页输入商品 ID/数量（本轮没有顾客商品目录过程），价格/库存仍由数据库定 |
| `app/templates/customer/index.html` | 顾客自助三表单与结果展示；取餐码只经 POST 返回，不写 URL |
| `app/inventory/` | 库存看板、流水、补货创建/调整/提交/审批/驳回、收货、员工角色页 |
| `run.py` | Flask 启动入口；`pyodbc.pooling = False` 进程级兜底 |
| `tests/stage2/auth` / `inventory` / `customer` | 10 + 12 + 10 条 fake-DB 测试；`run-all.ps1` 六套汇总 |
| `sql/stage2/provision_employee.template.ps1` | 员工 SQL 登录/同名用户/EmployeeAccount 映射模板（口令由操作者输入） |
| `sql/stage2/provision_customer.template.ps1` | `cust_app` 的 SQL 登录/映射模板；只核三个 EXECUTE，不授予额外权限（口令由操作者输入） |

## 3. 本轮核验结果

| 核验 | 实际结果 | 判定方法 |
| --- | --- | --- |
| 真实 25 表采集 | 25 表 / 178 行，**25/0** | A/B/C 真 `baseline_*`；逐表逐值双向 `EXCEPT` |
| 真实 `run_migration`（11a→11b→11c→12） | **15 个过程 / 3 个 `cust_app` GRANT / 58 码 / 71 行** | B 真实 `11b`、A 真实 `11a`（含 register）、C 真实 `11c/12`；**无临时桩** |
| `regression` | **38/0** | 13a 10 + 13b 5 + 13b write 8 + 13c 15；真实 v1.0 |
| `tests/stage2/inventory-security` | **15/0** | 真实 v1.0 上运行 13c；独立入口需数据库，不并入 fake-DB run-all |
| `13c` | **15/0** | 目录/映射/GRANT/cust_app/上下文/UQ/账本/建议/签名/视图/员工角色 229 |
| `cust_app` 三过程 | **3/0** | `EXECUTE AS USER='cust_app'` 实调 register/place/list，事务内回滚；证据 `c-customer-custapp-2026-11-09.txt` |
| 签名三路径 | **3/0** | 真实 v0.1；低权限店长实际调用 + 普通岗位 229 |
| auth / inventory / customer | **10/0 / 12/0 / 10/0** | 登录注销与 cookie、库存输入边界、顾客三表单与参数定型 |
| 既有 app 回归 | common 18/0、master 36/0、orders 20/0；run-all 六套 **106/0** | 2026-11-09 `run-all.ps1 -Python` 实跑，证据 `c-runall-customer-2026-11-09.txt` |
| C HTTP smoke（临时 SQL 登录） | **3/0** | store/master/inventory/orders、五个 B 岗位订单页、shift 库存页；顾客建档→下单→取餐码查单；随机口令不打印、跑完清理 |

## 4. 决策与边界

- **已关闭**：OI-10（三顾客过程 + 12 授权 + 13c）、OI-14（Common 多结果集）、OI-15（员工角色查询）、OI-16（驱动池）、OI-17（`run-all` 解释器）、OI-18（B 11b）、OI-19（`@customer_name`）。
- **仍 open（非阻塞）**：OI-20（历史审计脚本硬编码仓库根；C/B 各自属主下次处理）、OI-05/OI-11 等礼节项。
- **已完成**：真实 11b 迁移与 38 条回归；顾客页、`cust_app` 模板、六套应用测试；`KFC_DB` 测试后删除。
- **已完成/边界**：C 已用随机临时 SQL 登录做技术 HTTP smoke（3/0），口令不打印、跑完删除；正式顾客/员工登录映射仍需操作者执行模板并配置 `.env`，再由 A/B/C 做浏览器联合验收。A 的操作手册/README 仍可能写“顾客页待交付”，需 A 按本报告更新。C 不以 fake DAO、`EXECUTE AS` 或 B 的联调记录冒充正式联合验收。
- `cust_app` 三过程由 `12` 条件授权；缺失时 `13c-7` 必须失败，不以空列表冒充成功。

## 5. 下一步

1. 操作者执行 `provision_customer.template.ps1`，在 `.env` 配置顾客登录；用真实浏览器走通建档→下单→取餐码查单→响应丢失边界。
2. A 更新操作手册/README 的顾客页与六套测试入口；B 的订单工作台入口按联合验收补链接。
3. 处理 OI-20 的 C 侧历史脚本路径（不阻塞验收）。
4. 收尾保留本报告、测试报告、证据 README 与数据字典 v1.0 一致；不再使用临时桩。
