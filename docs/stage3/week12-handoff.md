# 第三阶段第 12 周交接（A）

> 属主：A。来源：2026-11-18 收到的《第十二周任务讲解》。本文只记录按讲解核对后**改变的结论与行动项**，完整分工仍以 [三人协作实施计划](three-person-implementation-plan.md) §2.3、§6 为准。
> 第 13 周讲解尚未收到，并发部分仍按周次表推导、标“待核”。

## 1. 三条结论

| 事项 | 讲解要求 | 本仓决定 | 理由 |
| --- | --- | --- | --- |
| 递归查询 | 以“商品分类—子分类”为例，建立带父级编号的层级关系 | **保留 `24b_recursive_query.sql` 的套餐组件树**（`SalesOrderItem.parent_order_item_id`），不新增分类父级列 | 作业同时允许“层级表或已有结构说明”；`Category` 没有父级列，改用分类树要重开 v1.1 冻结范围，并同步 C 的 `20`/schema 测试与 B 的 `13b` 列数检查，风险高于收益 |
| 订单完成事务 | 事务内检查状态、明细、数量、库存，扣减库存并更新完成状态 | **事务主体改为 `sp_finish_production`**；库存实扣只经 `sp_consume_order_inventory`，取餐/送达不再扣 | 本库下单只锁库，实扣发生在制作完成；原计划的取餐/送达过程不扣库存，不能证明“事务内扣减” |
| 补货入库事务 | 检查商品、数量、单据状态；重复收货不能重复加库存 | 保留 C 的 `25c`，补“同一已入库/已关闭单据再次收货必须拒绝、库存不增加”的验收 | 与讲解一致，只补验收点 |

## 2. 对 B 的行动项

1. **`24b_recursive_query.sql`**
   - 写清自引用关系、根节点定义（顶层售卖项）与样例数据；
   - 锚点 + 递归连接 + 终止条件齐全；路径判重防环，`OPTION (MAXRECURSION 10)`；路径列两段同类型同长度；
   - 分别输出根节点、中间节点、叶子节点、不存在编号的结果，与样例关系逐层对照。
2. **`25b_tx_order_completion.sql`**
   - 以 `IN_PRODUCTION` 订单为输入，事务内调 `sp_finish_production`，断言 `READY_FOR_PICKUP`/`READY_FOR_DELIVERY`、`production_finished_at`、库存与锁定量同减、`CONSUME` 流水（外送另有 `Delivery` 行）；
   - 补拒绝路径：不存在、已完成、无明细、库存/锁定量不足、连续两次制作完成；
   - 回滚路径：过程成功后 `THROW`，订单、库存、流水、配送行全部恢复，`@@TRANCOUNT = 0`；
   - 金额核对：`SalesOrder.total_amount = SUM(gross_amount - discount_amount)`（v1.0 存量折扣为 0，按毛额）。
3. 不把实扣搬到 `sp_pick_up_order` / `sp_confirm_delivery`；终态只改状态与积分。

## 3. 对 C 的行动项

1. **`docs/stage3/source-requirements.md`** 的 R3-01/R3-02 从“待核”改为本页的落点与状态；R3-03 补“重复收货拒绝”验收点。
2. `run_stage3.sql` / `verify_stage3.sql` 的对象清单不需要因递归查询改动；若 25b 需要临时夹具，仍按计划在临时副本执行提交路径。
3. `open-issues.md` 无需新增条目；S3-02 的 A 回执已在 `result/stage3/a-review-s3-02.md`。

## 4. A 自己的收尾

- 提供 25b 的金额/折扣断言素材（`total_amount` 与明细净额之和），已落 `result/stage3/a-order-tx-assertions.md`；
- 第 12 周 README、阶段报告素材与 AI 记录按计划 §6.4 同步；
- `app/reports/` 真库联调仍等 B 的 `21b`。

## 5. 依据

- [三人协作实施计划 §2.3、§6](three-person-implementation-plan.md)
- [销售与折扣语义](sales-semantics.md)
- `sql/stage1/06_inventory_constraints_crud.sql` 的 `sp_consume_order_inventory`、`05_order_constraints_crud.sql` 的 `sp_finish_production`
