# A 对 S3-02 的评审回执（InventoryAudit 外键 vs DELETE）

> 评审人：A；对象：`sql/stage3/20_schema_v1_1.sql`、`sql/stage3/22c_inventory_triggers.sql`。
> 对应 `docs/stage3/open-issues.md` S3-02。本文只给结论与理由，不改 C 的文件。

## 结论

**同意 C 当前实现（方案①）：保留 `InventoryAudit.ingredient_id → Inventory.ingredient_id` 外键，`tr_Inventory_Audit` 的 DELETE 分支保留为防御性代码。**

## 理由

1. **库存行不是可删除的业务实体。** v1.0 的业务角色没有 `Inventory` 的 DELETE 授权；补货、调整、锁定都走状态与数量变更，不删行。把“库存行不可删除”作为不变量，比让审计表保存指向已删主数据的历史行更符合主数据口径。
2. **外键保证审计的归属。** 审计行要回答“哪个原料从多少变到多少”；如果去掉外键，`ingredient_id` 可能指向已不存在的主数据，后续按原料汇总库存历史时会出现孤儿键。当前不存在删除路径，保留外键没有业务代价。
3. **DELETE 分支仍有价值。** 触发器是集合处理，保留 DELETE 分支可以在未来放宽授权或做数据修复时留下完整轨迹；只是在外键存在时，父行删除会先被外键拒绝，这属于预期的“不允许物理删除”，不是触发器缺陷。

## 落地条件

- 数据字典与 `open-issues` 明确写：`Inventory` 行不允许物理 DELETE；停用原料走状态，不删行。
- 应用层不得新增 `DELETE FROM Inventory`；现有库存页只做调整与建议，不提供删除入口。
- 若将来确需清理历史库存行，必须先决定审计保留策略（先迁审计、再删父行，或改为软删除），不能直接 `DROP` 外键绕过。
- C 的 `22c` 测试已覆盖 INSERT/UPDATE/多行，DELETE 分支保持“防御性、未作为业务路径验收”即可；不需要为它放宽外键。

## 对 S3-02 的建议状态

A 侧回执完成；是否关闭由 C 在 `docs/stage3/open-issues.md` 更新。
