# A 对 B `25b_tx_order_completion.sql` 的审阅

> 审阅人：A；对象：`sql/stage3/25b_tx_order_completion.sql`（B，2026-11-24 交付）。
> 依据：`docs/stage3/three-person-implementation-plan.md` §6.2、`sales-semantics.md` §2.4、`result/stage3/a-order-tx-assertions.md`。本文只给结论，不改 B 的文件。

## 结论

**通过。** B 的 25b 覆盖了 A 在 `a-order-tx-assertions.md` 中要求的关键断言，没有发现需要 A 侧修改的问题。

## 对照检查

| A 的断言 | 25b 的实现/证据 | 结论 |
| --- | --- | --- |
| `total_amount = SUM(ROUND(unit_price*quantity,2) - discount_amount)` | 第 131–134 行取 `SELLABLE` 行计算 `gross - discount`，不一致抛 `54225`；B 证据 `b-24b-25b` 的 net 列与之一致 | 通过 |
| 制作完成后状态为 `READY_FOR_PICKUP` / `READY_FOR_DELIVERY`，写 `production_finished_at` | 第 140–144 行检查 `@ready` 与 `production_finished_at`；B 证据 7 个场景 | 通过 |
| `on_hand_qty` 与 `locked_qty` 同减，`CONSUME` 流水形状正确 | 第 145–158 行对 `@reserved` 逐原料比较前后值，并用 `EXCEPT` 校验 `CONSUME` 的 `-qty/-qty` | 通过 |
| 外送恰好一行 `Delivery`，自取不生成 | 第 160–162 行按履约方式断言 | 通过 |
| 失败路径：不存在、无售卖明细、无待实扣锁定量、锁定量不足 | 用例 4–7，期望 `52401` / `52402` / `50000`；B 证据 7 个场景 | 通过 |
| 回滚：成功后注入失败，订单/库存/流水/Delivery 全部恢复，`@@TRANCOUNT=0` | 用例 3 注入 `54222`，第 176–194 行比较 JSON 快照与库存/单据状态 | 通过 |
| 重复制作完成：第二次被 `52401` 拒绝且无变化 | 第 211–257 行循环两次，检查错误码、事务计数和快照不变 | 通过 |
| 不在取餐/送达终态重复扣库存 | 25b 只调 `sp_finish_production`；终态路径由既有过程处理，未重复扣减 | 通过 |

## 边界

- 25b 在 `KFC_B_STAGE3_*` 一次性库运行（第 6–8 行守卫），不会写业务库；这是正确的隔离方式。
- 25b 是单会话事务验收；第十三周要求的“订单事务 vs 补货事务”双会话等待、两笔 P×6 并发购买属于新的 `26b`，不在 25b 范围内，不能拿 25b 代替。
- B 的证据 `result/stage3/b-24b-25b-2026-11-18.txt` 显示 36/0；A 本次只做代码/证据审阅，没有在 B 的一次性库上独立重跑。正式联合验收仍以 C 的 `verify_stage3` 和 B 的 runner 为准。
