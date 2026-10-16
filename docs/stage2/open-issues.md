# 跨域开放问题登记表（open-issues）

> 属主：成员 C（计划 §7.1）。**本表是第二阶段跨域问题的唯一状态入口**：计划 §2、三份域 issues 文件（`a/b/c-issues.md`）与本表引用同一 ID，不另维护冲突状态；域内问题的完整信息在各域文件，本表只记跨域状态与决议指针。
>
> 状态口径：`open` 未决 / `in-progress` 处理中 / `closed` 已决议（附证据指针）/ `deferred` 有决议但延后执行。
>
> 维护约定：新增行由发现者添加并通知 C 合入；状态与决议由 C 统一更新；每次 2.x 收口时全表过一遍。

| ID | 问题 | 域素材 / 落点 | 状态 | 负责人 | 截止 | 决议与验收证据 |
| --- | --- | --- | --- | --- | --- | --- |
| OI-01 | **教学原文核对**（范围总开关；原文缺失时阻断范围冻结与 2.1 收口） | `docs/stage2/source-requirements.md` | **closed（2026-10-13）** | C | 2.1 开工 | 逐条核对完成：36 项要求全部有落点，无新增范围项、无冲突项；用户提供的两份 docx 按其要求不归档、核对后删除；证据 = `source-requirements.md` |
| OI-02 | **供应商实体是否引入** | 计划 §2.1 保留项 + `c-issues.md` I-C07 | closed（2026-10-10 计划定；2026-10-13 原文核对补强） | C | — | 判断为不引入：原文只要求"说明含义并判断是否独立保存"，判断与理由已归档；`PurchaseOrder` 保持 6 列 |
| OI-03 | **2.2 设计冻结日期**（范式 / 重构结论的冰冻线） | 计划 §7.2 | open | 全组 | 2.1 收口时登记 | 待 2.1 收口由三人共同确认后填入本行 |
| OI-04 | **包含数据库用户替代登录路径**（§6.1 默认路径的潜在替代） | 计划 §6.1 + `c-issues.md` I-C05/I-C11 | deferred | A、C | 2.3 预检前 | 未采纳为默认（保持"SQL 登录名 + 同名映射数据库用户"唯一口径）；如需替换，须 A/C 联合验收 + 修订计划 / 契约 / 部署模板；我方实验证据已归档 `result/stage2/`（含混合模式前置事实） |
| OI-05 | **`08` 的 DMK 明文口令取舍**（第一阶段遗留礼节项） | 计划 §11 变更记录 | open | 三人 | 阶段交付前 | A 已表态认同 C 立场、建议三人拍板；不影响任何验收 |
| OI-06 | **`Ingredient` / `AuditLog` 的域属主更正**（影响合图与 `11a` / `11c` 迁移归属） | `c-issues.md` §1 + 计划 §4/§5 | **closed（2026-10-14）** | A 发现，C 域文件已改 | 2.1 收口前 | 按建表位置：`Ingredient` 在 `sql/01_master_schema.sql:34`（A 域），`AuditLog` 在 `sql/03_inventory_security_schema.sql:167`（C 域）。`c-issues.md` §1 已把误列的 `Ingredient` 换成 `AuditLog`，`Ingredient` 的三处跨域外码引用（`Inventory` / `ReplenishmentSuggestion` / `PurchaseOrderItem`）保留、在 C 域子图按灰矩形处理。若不改，合图会出现 `AuditLog` 无落点、`Ingredient` 重复，违反 §4「25 表全部有落点」 |
| OI-07 | **`legend.md` §2 端点符号的措辞与实际画法相反**（照字面画会把两端基数画反；影响三份域子图与合并总图） | `docs/er/legend.md`（§2 第 2 条，`legend.md:22`）+ `docs/er/a-master.drawio` / `c-inventory-security.drawio` | open | A 发现；按 `legend.md` §3.4 由图例属主 C 修订措辞 | 2.1 收口前 | 该条写作「近实体端的符号描述"本实体侧每条记录对应多少个对端"」，与两人实际画法互为反向。实际口径为「某端的符号描述**对端每条记录对应多少条本端记录**」，即鸦爪恒在"多"端。证据：C 图 `Inventory → InventoryMovement` 标签 `1:N`，`startArrow=ERone`（`Inventory` 端）、`endArrow=ERzeroToMany`（`InventoryMovement` 端）；`EmployeeAccount → PurchaseOrder`（`approved_by` 可空、`1:N`）为 `startArrow=ERzeroToOne` / `endArrow=ERzeroToMany`；A 图 r16（`Promotion` → `SalesOrderItem`）同形。照字面照抄确会画反：A 图 r7（`MemberLevel` — `Customer`）原按字面画成鸦爪在 `MemberLevel` 端，与其余 15 条联系及 C 域两图不一致，2026-10-16 已改回（`Customer` 端鸦爪、`MemberLevel` 端 `ERzeroToOne`），A 图 16 条端点自查 16/16 通过。只需改措辞，四种端点符号名与组合不变，三张图的端点无需改动 |

## 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-13 | 建表：登记 OI-01（closed，教学核对完成）、OI-02（closed，供应商）、OI-03（open，冻结日期）、OI-04（deferred，包含用户路径）、OI-05（open，DMK 取舍） |
| 2026-10-14 | 订正 OI-05 的落点引用：计划「变更记录」在第 §11 节，原文误写为 §8（§8 是开工前置项） |
| 2026-10-14 | 登记 OI-06（closed）：`c-issues.md` §1 误列 `Ingredient` 为 C 域、漏 `AuditLog`，已按建表位置换回；`Ingredient` 跨域外码引用保留 |
| 2026-10-15 | OI-06 收尾（C）：`docs/er/c-inventory-security.drawio` / `.svg` 已订正——`Ingredient` 转灰矩形（A 域、3 列）、`AuditLog` 补入（7 列），新增 `EmployeeAccount → AuditLog` 1:N 联系（折线走线避开 `Delivery`）；共 12 实体 14 联系，几何避让自查 0 冲突 |
| 2026-10-16 | 登记 OI-07（open，A 发现）：`legend.md` §2 端点符号措辞与实际画法相反；A 图 r7（`MemberLevel` — `Customer`）按字面画反的端点在本次一并改回 |
| 2026-10-16 | 存档 A 域主数据与定价 ER 子图：`docs/er/a-master.drawio` / `.svg`（16 实体 16 联系、0 处几何冲突），提交 `810465d` |
| 2026-10-16 | A 域子图版面调整：6 条联系标签（r1/r2/r5/r6/r7/r14）宽度超过 80px 列间距，压住了相邻实体的属性行；加宽 col1↔col2 走廊 80→400、col2↔col3 80→360（col3/col4 随之右移，col3↔col4 保持 120），18 个拐点同步平移；r3/r4 两条标签原先互相压 11px，改为上下错开 ±18。**标签文字与实体内容一字未改**，`.svg` 重导为 2022×1113，实测 16/16 标签不压框、0 条折线穿框 |
