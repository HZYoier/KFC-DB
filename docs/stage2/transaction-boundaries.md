# B 主笔：业务事务边界与应用调用规范

> 2026-10-14；依据既有 B 过程和[跨域契约](../stage1-cross-domain-interface-contract.md)整理。
> 数据库现状为源码已实现；应用 helper、故障注入及 v1.0 测试是后续验收要求，不是本轮运行结果。

## 1. 八个业务入口

| 过程 / 岗位 | 同一事务内必须一起成功的写入 | 调用 A/C | 禁止的半成功 |
| --- | --- | --- | --- |
| sp_create_order / CASHIER | 订单、售卖/组件快照、总额、原料锁及 LOCK 流水 | A 定价函数；C sp_lock_order_inventory | 有订单无明细，或有订单无库存锁 |
| sp_pay_order / CASHIER | Payment SUCCESS、订单 PAID/paid_at、PointLedger PENDING | 读取 A 当前会员倍率，不直接改顾客 | 有支付无待生效积分 |
| sp_start_production / CHEF | PAID → IN_PRODUCTION、开始时间 | 无 | 跳过支付开始制作 |
| sp_finish_production / PACKER | 实扣及库存流水、订单待取/待配送、结束时间；外送配送 WAITING_PICKUP | C sp_consume_order_inventory | 库存已扣、订单仍制作中 |
| sp_pick_up_order / PACKER | 自取终态、完成时间、积分 EFFECTIVE、顾客累计及等级 | A sp_apply_customer_points | 订单完成但积分未入账 |
| sp_pick_up_delivery / RIDER | 订单 DELIVERING、配送认领/时间、真实骑手绑定 | 读取 C EmployeeAccount | 订单配送中但无骑手 |
| sp_confirm_delivery / RIDER | 订单 COMPLETED、配送 DELIVERED、送达/完成时间、积分入账 | A sp_apply_customer_points | 已送达但积分仍 PENDING |
| sp_cancel_or_refund_order / STORE_MANAGER | 释放锁/流水、订单 CANCELLED；已付则全额退款与积分 VOIDED；审计 | C sp_release_order_inventory、sp_write_audit_log | 库存已释放但退款/审计失败仍提交 |

Customer、Inventory、AuditLog 的写入始终由属主过程处理，B 不跨域直接 DML。

## 2. 状态与原因

自取：PENDING_PAYMENT → PAID → IN_PRODUCTION → READY_FOR_PICKUP → PICKED_UP。
外送：PENDING_PAYMENT → PAID → IN_PRODUCTION → READY_FOR_DELIVERY → DELIVERING → COMPLETED。
未支付取消 reason 为 CANCEL 或 PAYMENT_TIMEOUT；PAID/IN_PRODUCTION 仅在未实扣时 REFUND。已实扣、已取餐或已送达不能按本流程退款；无部分退款。
PAYMENT_TIMEOUT 是受控调用原因，不表示已实现自动计时任务。

## 3. 连接、身份和嵌套事务

- 应用一次业务按钮默认调用一个过程，不跨顾客支付等待、后厨制作或骑手配送维持事务。
- Flask员工请求通过 `app/common/db.py` / `tx.py` 使用同一真实员工身份、同一连接；显式绑定类型/长度/精度，走pyodbc占位。数据库自行按 USER_NAME() 校验活跃岗位，员工 ID 参数必须与解析身份一致。顾客请求不创建员工上下文，走独立cust_app与专用过程。
- B 过程入口保存 @@TRANCOUNT：0 时自行 BEGIN/COMMIT；已有事务时 SAVE TRANSACTION，不提交调用方事务。
- 捕获异常：自持事务整体回滚；嵌套且 XACT_STATE()=1 时回滚保存点；=-1 时不能回滚保存点，必须把异常传给外层整体回滚。应用 helper 不得捕获后继续提交，也不能只看异常文本。
- 一个 helper 只服务确有原子需求的多过程调用，不能把整个“下单→支付→制作→配送”包成一次事务；SQL编号、原消息和异常链仅供后端日志，前端只收共同 `{code,message,request_id}` 和安全文案，不泄露数据库细节或凭据。

## 4. 并发与重试

现有过程先验证员工，再对订单/支付/配送/积分等所需行使用 UPDLOCK/HOLDLOCK；C 在自己的接口持有库存锁。这里不宣称所有跨域路径已有统一死锁证明，集成时必须实测。
两骑手认领同单只能一人提交；重复支付、完成和退款按状态机/唯一约束拒绝，不等于 API 已实现“重复请求返回上次成功”。
断线、超时或死锁后先回滚/释放本地事务；若提交结果不确定，通过未来 B 状态查询确认订单、支付和积分事实，禁止自动再次扣款。订单号唯一用于结果查找，不声称已有完整请求幂等协议。
不在读取错误结果后按客户端缓存自行补写顾客积分或库存。

## 5. 共享底座交接要求

| 输入 | 参数类型 | 需验证的边界 |
| --- | --- | --- |
| order_id / customer_id / rider_employee_id / operator_employee_id | BIGINT | 不是 INT；正数、身份不匹配 |
| items_json | NVARCHAR(MAX) | Unicode、长 JSON、[]、重复键、非法角色/价格输入 |
| order_no | VARCHAR(50) | 空白、超长、重复；不静默截断 |
| fulfillment_method / payment_method / reason | VARCHAR(20) | 白名单与状态匹配 |
| paid_amount | DECIMAL(10,2) | precision=10、scale=2；不经浮点转换，越界拒绝 |
| third_party_txn_no | VARCHAR(100)，可空 | Python显式传None（SQL NULL），禁止空字符串冒充NULL；无默认值不能省略 |
| ordered_at | DATETIME2(0)，可空 | 正常应用不提供历史时间；仅受控 test_* 可传 |

A 定 Common 的实际语言签名；B 提供这些用例、按接口适配，不自行创建第二套连接工厂。C 定登录和授权。新查询过程签名/错误码尚待契约冻结，不在本文件擅自命名编码。

2026-10-24技术栈同步：唯一接口为A的 `open_connection(session)`、`query_procedure(session,name,typed_parameters)`、`execute_procedure(session,name,typed_parameters)`、`run_in_transaction(session,callback)`；B目标目录为 `app/orders/{routes,service,dao}.py`，路由不写SQL、DAO不另开连接底座，错误统一交 `app/common/errors.py` 与Flask全局处理。当前底座尚未交付，不创建自己的Common或凭据存储。每请求结束关闭连接，关闭驱动池是A的职责；`pyodbc.pooling = False` 应在首次连接前设置，不应当作连接串参数，依据[pyodbc官方源码说明](https://github.com/mkleehammer/pyodbc/blob/master/src/pyodbcmodule.cpp)。具体初始化由A确认。跨请求真实身份恢复问题见[B决策材料](b-contract-decisions.md) §5。

## 6. 后续 13b / 应用测试矩阵

| ID | 场景 | 应核对的结果 | 所需协作 |
| --- | --- | --- | --- |
| BT-01 | 空数组、非对象、客户端报价或重复 JSON 键 | 精确错误码；无订单、支付、积分或库存副作用 | B 自有输入案例 |
| BT-02 | 真实订单和 A 定价 | 成交价/促销快照；套餐组件价零；总额不重复 | A 正常商品与价格 |
| BT-03 | 库存不足 | C 异常原样传播，B 主子表与 C 流水同时回滚 | C 可控不足场景 |
| BT-04 | 重复支付、金额不符 | 至多一条 Payment/PointLedger，失败不改状态 | B；A 会员倍率 |
| BT-05 | 完成时 A 积分失败 | 订单/配送/流水/顾客全部回滚 | A/C 隔离副本故障方案 |
| BT-06 | C 实扣或审计失败 | 制作/退款与库存/审计原子回滚 | C 隔离故障方案 |
| BT-07 | 两骑手并发认领 | 恰好一人成功，订单与配送骑手一致 | C 两个真实员工账号 |
| BT-08 | helper 中第二步抛错 | 外层没有提交任何第一步写入，连接可安全释放 | A Common |
| BT-09 | 注销换号、停用、跨骑手确认 | 数据库拒绝越权；无上次会话身份泄漏 | A/C Auth/Common |
| BT-10 | 断线后结果确认 | 查询服务端结果后才能决定重试；不重复支付 | B 查询 + A Common + C 授权 |
| BT-11 | 同商品多行规则 | 按 I-B08 最终决议检验输入；图中不误加唯一键 | C 需求确认 |

测试须在副本/可回滚夹具中运行，故障注入不改共享业务库对象；跨域造数方案先由属主提供。每项记录期望、实际、错误码、原始消息、清理情况和退出码。
