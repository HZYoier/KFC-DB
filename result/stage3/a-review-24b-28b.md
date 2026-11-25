# A 对 B `24b` / `28b` 的审阅

> 审阅人：A；对象：`sql/stage3/24b_recursive_query.sql`、`sql/stage3/28b_stage3_regression.sql`（B，2026-11-24 交付）。
> 依据：计划 §6.1、`sales-semantics.md` §1、B 的证据 `result/stage3/b-24b-25b-2026-11-18.txt` 与 `b-joint-verification-2026-11-24.txt`。只审阅，不改 B 文件。

## 24b 递归查询

**结论：通过。**

- 锚点是 `parent_order_item_id IS NULL AND item_role = 'SELLABLE'`，递归连接是同一订单内子项 `parent_order_item_id = 父 order_item_id`，有终止条件；
- `item_path` 在锚点与递归两段都是 `VARCHAR(256)`，递归前用 `CHARINDEX` 判重，配合 `OPTION (MAXRECURSION 10)` 防环；
- 输出 `depth / item_path / expanded_quantity / quantity_per_parent / line_amount`，满足根/中间/叶子/不存在节点和子树查询；
- `quantity_per_parent` 只除直接父项数量，不重新套用实时套餐配方；`expanded_quantity` 使用订单明细快照数量；
- 只读，不写测试数据；B 的证据覆盖一层、临时两层、根/中间/叶子/不存在，36/0。

**注意：** 种子/应用当前只产生一层套餐；两层递归是测试夹具，B 已在证据中说明，不把“当前应用会产生两层”写成事实。

## 28b 回归

**结论：通过。**

- 前置检查 v1.1 标记、`v_settled_sales_line`、`sp_sales_report`、完成触发器、折扣列；
- 2 条销售日期错误（`54201/54202`）+ 6 条完成触发器/视图场景，合计 8 条，固定分母 `pass=8`；
- 折扣净额、`v_settled_sales_line` 两笔已结算行、触发器拒绝与批量状态更新都有断言；
- 所有夹具在事务内插入并 `ROLLBACK`，结束检查 `@@TRANCOUNT`、订单/商品残留；
- B 的联合验收显示 28b 8/0。

**边界：** 28b 依赖 v1.1 标记，B 的联合验收使用“域对象演练”的 v1.1 标记；正式 `run_stage3` 还要等 C 的 `27_permissions.sql` 后按完整入口重跑。
