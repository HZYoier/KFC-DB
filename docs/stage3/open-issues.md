# 第三阶段跨域开放问题（C 维护）

> 属主：C（总集成）。本表只记第三阶段新发现、需要 A/B 回执或跨域协调的事项；第二阶段遗留的 OI-05/OI-11/OI-20 仍在 `docs/stage2/open-issues.md`，不重复编号。
>
> 状态口径：`open` / `in-progress` / `closed` / `deferred`。C 侧能独立完成的实现不因本表停摆；涉及 A/B 文件的部分只登记，不代改。

| ID | 问题 | 影响 | 状态 | 负责人 | 建议/验收 |
| --- | --- | --- | --- | --- | --- |
| S3-01 | **`app/common/errors.py` 未映射 C 的 543xx 业务错误码**。C 的 `sp_adjust_inventory` 已按计划把拒绝路径统一到 54301—54308；A 原先的 `_SQL_NUMBER` 只登记 50000/510xx/52xxx/530xx，543xx 会落到 `E_INTERNAL`（HTTP 500）。 | 员工库存调整页的失败提示与 HTTP 状态退化；不改变数据库拒绝本身。 | **closed（2026-11-18）** | A / C | A 已按建议映射 54301–54303→E_INPUT、54304–54306→E_FORBIDDEN、54307→E_NOTFOUND、54308→E_RULE；C 复跑 common **18/0**，映射断言覆盖 54301–54308。证据：`app/common/errors.py`、`tests/stage2/common/test_common.py`。 |
| S3-02 | **`InventoryAudit.ingredient_id` 外键与 `tr_Inventory_Audit` 的 DELETE 分支相互制约**。`20_schema_v1_1.sql` 建了到 `Inventory` 的外键；`22c` 的 AFTER DELETE 触发器要写相同 `ingredient_id` 的审计行，但父行已删除时外键会让整条 DELETE 失败。 | 直接删除有审计的 `Inventory` 行会被数据库拒绝；正常业务角色没有 DELETE 授权，当前不影响 22c 的 INSERT/UPDATE 测试。 | **closed（2026-11-18）** | A / C | A 已回执同意方案①（`result/stage3/a-review-s3-02.md`）：库存行不允许物理 DELETE，保留外键，DELETE 分支作为防御性代码，不为其放宽外键。C 已用 INSERT/UPDATE/多行测试 **10/0**，并在库存权限数据字典写明停用原料走状态、不删行。 |
| S3-03 | **B 的 `13b_order_baseline_check.sql` 仍按 v1.0 的 10 列校验 `SalesOrderItem`，v1.1 的折扣两列使 shape 检查报 51961**。该文件属 B，C 不代改；`13b_order_write_contract_check.sql` 单独跑仍是 8/8 | v1.1 上 `regression.sql` 无法达到 38/0；13a 10/0、13b write 8/8、13c 15/0 已通过；七套应用 118/0 通过 | open | B | 按 `sales-semantics.md` F-01 改为版本感知：v1.1 期望 `SalesOrderItem` 12 列，shape/逐值比较只使用 v1.0 基线列，或把新增两列加入允许集合；改完在 v1.1 上重跑 `regression.sql` 38/0 |

## 变更记录

| 日期 | 事项 |
| --- | --- |
| 2026-11-15 | 建立；登记 S3-01（543xx 应用映射）、S3-02（审计外键 vs DELETE）、S3-03（13b 仍按 10 列）。C 的 3.1 对象与 C 侧测试不受阻；完整 v1.0 regression 待 B |
| 2026-11-18 | S3-01 关闭（A 映射 543xx，C 复跑 common 18/0）；S3-02 关闭（A 回执同意保留外键、库存行不物理 DELETE，C 数据字典同步）；S3-03 仍 open 等 B 版本化 13b |
