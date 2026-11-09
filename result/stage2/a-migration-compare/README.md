# A 迁移前后关键查询对照（2026-11-09，v1.0 真实库）

> 属主：A（主数据、定价、会员）。本目录回答一个问题：就地迁移 v0.1 → v1.0 之后，**业务数据有没有被改坏**。做法是把 `MigrationBaseline_*` 快照（`batch_id = 1`）与迁移后的 `dbo.*` 业务表逐行比一遍，而不是只看"迁移没报错"。

## 环境

- 实例 `localhost`（SQL Server 2025 Express），库 `KFC_DB`，由第一阶段 v0.1 **就地迁移**而来，没有换库名、没有删库。
- 批次：`batch_id = 1`、`source_baseline = v0.1-2026-10-03`、`capture_scope_version = 2.2-v1`、`schema_digest = EFD5DDE844DA475F0AE0DA1CD11AA7111BC10A28A4EE21A0BDCBEEFB24AD8245`；迁移后 `SchemaVersion('v1.0')` 的 `object_digest = 56A8CE697200F3A13BDD3CA08A5F6B138731786CB8ABE65487DCE52F98D66C2D`。
- 只读脚本，不改任何数据；跑在 `run_migration.sql` 提交之后。

## 复现

在仓库根目录执行（`-i` 用相对路径）：

```powershell
sqlcmd -S localhost -E -C -f 65001 -b -I -i "result/stage2/a-migration-compare/check_a_migration_compare_20261109.sql"
```

脚本以 `THROW 53521` 断言零差异：任一组对账不为 0 时退出码非 0（`-b` 生效）。

## 结论（`a-migration-compare-2026-11-09.txt` 摘要）

| 指标 | 迁移前 | 迁移后 | 判定 |
| --- | --- | --- | --- |
| 订单数 / 订单总额 | 3 / 47.90 | 3 / 47.90 | 一致 |
| 订单明细行数 / 售出总份数 / 明细金额合计 | 3 / 3 / 47.90 | 3 / 3 / 47.90 | 一致 |
| 商品数 | 6 | 6 | 一致 |
| 库存行数 / 在库总量 / 锁定总量 | 6 / 34338.00 / 0.00 | 6 / 34338.00 / 0.00 | 一致 |
| 顾客数 / 积分余额合计 | 3 / 2028 | 3 / 2028 | 一致 |
| 业务表数 | 25 | 26 | 变化：新增 `Permission` 表（`RolePermission` 拆分的产物） |
| 角色授权行数 | 52 | 71 | 变化：按 v1.0 权限码重建，预期增 |
| 权限码数 | 46 | 58 | 变化：v1.0 权限目录，预期增 |

- 订单、订单明细、库存、顾客**四组逐行对账差异全 0**（仅迁移后存在 / 仅基线有 / 字段不一致均为 0）。
- 权限侧是"只增不减"：基线里的 46 个权限码迁移后一个不少（差集 0），同码的名称不一致 0 处，新增 12 个（如 `sp_list_master_records` 主数据记录查询、`sp_register_customer_for_order` 收银顾客建档）。
- 抽样三张订单：`B-SEED-PICKUP-001`（`PICKED_UP`，9.90）、`B-SEED-DELIVERY-001`（`COMPLETED`，19.00）、`B-SEED-CANCEL-001`（`CANCELLED`，19.00），状态与金额迁移前后逐条相同。

## 口径与边界

- 只比业务事实列：订单比 `total_amount` / `order_status`，明细比 `product_id` / `quantity` / `unit_price`，库存比 `on_hand_qty` / `locked_qty`，顾客比 `current_points` / `member_level_id` / `status`。**不比审计时间戳**——迁移会重写 `updated_at` 一类列，那属于过程不是数据。
- 也不比约束、索引的形态：那些由 `12_permissions` 与三域迁移脚本负责，结论落在 `regression` 38/0 与 `13a`–`13c` 的断言里。
- 本库是种子数据（3 单 / 3 明细 / 6 库存行），对照能证明"迁移没有损坏现有行"，**不能**证明任意历史数据量下都无损。
- 与 C 的证据分工：`result/stage2/c-real-migration-2026-11-09.txt` 证明迁移整体成功（提交 v1.0、`regression` 38/0），本目录只负责"数据行像素级没变"。全组结论以 C 的迁移证据与 `docs/stage2/test-report.md` 为准。

## 文件

| 文件 | SHA-256 | 说明 |
| --- | --- | --- |
| `a-migration-compare-2026-11-09.txt` | `d92ca733ac1869969d9c29a391cd9179d81d2099eae09a1415bb90c9e7cf3db7` | `sqlcmd -o` 原始输出，UTF-8 with BOM |
| `check_a_migration_compare_20261109.sql` | `6c5fff01ad017fc5fa04ed6f4686c47847d9e5ba75f114da8ac9e7f54c13282f` | 只读对照脚本，可重跑 |

两个文件都在 `.gitattributes` 里标了 `-text`，换行按原字节保存，SHA-256 可逐字节复核。
