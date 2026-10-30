# 第二阶段重构方案：B 分析稿与全组汇总框架

> 主笔 B；2026-10-14建立，2026-10-30同步d741e24；R6-05/06/09。A人工复核及期初修订、C基线/白名单协议已交付；本文补全三域方案汇总，但**不是全组v1.0共同冻结批准**。
> [实施计划](../stage2-three-person-implementation-plan.md)与[开放问题表](open-issues.md)优先；不修改第一阶段 SQL。

## 1. 输入、决定与状态

| 域 | 现有输入 | 当前可用结论 | 仍缺的冻结输入 |
| --- | --- | --- | --- |
| A | a-issues.md、a-normalization.md、01/04/07a、共同契约、Common | 保留10表、五项唯一、期初offset与人工复核已收；共享层已交 | 共同日期确认；六新查询所需多结果集/异常传播修正 |
| B | b-issues、b-normalization、业务映射、冻结回执 | 保留五表、键/快照、总额与积分事件值；I-B08沿用顶层重复拒绝；53列baseline已交 | 本域11b矩阵见回执；共同冻结后执行11b/13b |
| C | c-issues、c-normalization、C子图、migration-guide、采集入口 | Permission拆分/唯一提案、固定CHECK落位、快照形状均明确 | C本人日期回执；签名三路径及真实完整采集执行验收 |

所有“推荐”只有在 OI-03 对应的冻结审查通过后转为实施项；未齐部分明确列缺口，不造签字或验收。

## 2. B 目标关系模式（保留方案）

属性全集与类型沿用[现有字典](../订单履约数据字典.md)，以下列码与依赖边界，不以省略号替代字段迁移说明：本方案没有删除、重命名或类型变化。

| 表 | 目标码 | 保留 / 变化理由 | 跨域依赖 |
| --- | --- | --- | --- |
| SalesOrder | PK order_id，UK order_no；自取码过滤唯一 | 保留总额并逐单对账；保存全生命周期时间戳 | A Customer；C 库存读取状态 |
| SalesOrderItem | PK order_item_id；父项自引用 | 保留历史父子快照；不新增 (order_id,product_id) 唯一约束 | A Product/Promotion/ComboComponent/BOM；C 锁库与实扣 |
| Payment | PK payment_id，UK order_id | 一次完整业务支付/全额退款，原实付保留 | A 会员倍率读取 |
| Delivery | PK delivery_id，UK order_id | 待认领→送达；骑手空值有业务含义 | C EmployeeAccount，骑手 FK 当前在 03 定义 |
| PointLedger | PK point_ledger_id，UK order_id | 保留计算积分作为事件值，公开反规范化 | A Customer/入账过程；C 员工鉴权 |

当前 B 无批准的拆表/合表，不伪造无损分解实验。PointLedger 理论分解及未采用理由在[b-normalization](b-normalization.md) §5；原模式保留时映射为恒等，业务数据不需要搬迁。
如冻结审查选择另一方案，B 必须先更新本文、图、字典和调用者矩阵，再写迁移，不把草稿推荐当免审许可。

## 3. 不变量与基线映射

| 基线内容 | 比较键 | 必须保持的内容 |
| --- | --- | --- |
| 订单 | order_id、order_no | 顾客、履约、状态、总额、所有时间戳与自取码 |
| 明细 | order_item_id | order_id、父项、角色、商品、数量、单价、促销；同单/组件形状 |
| 支付 | payment_id、order_id | 原实付、退款、方式、流水号、支付/退款时间 |
| 配送 | delivery_id、order_id | 骑手 NULL/非 NULL、状态、认领/送达时间 |
| 积分 | point_ledger_id、order_id | 顾客、实付/倍率/积分快照、状态、生效时间 |

金额两位小数；精确比较 NULL 与非 NULL，不能用 0 或空字符串替代。SalesOrder 总额与仅 SELLABLE 求和一致；COMPONENT 不重复计收入。订单销量只取 PICKED_UP/COMPLETED，取消与退款不算完成销量，按完成时间界定区间。
积分只把 EFFECTIVE 计为本库已生效流水，PENDING/VOIDED 分列；不把其和直接当 Customer 全历史余额。配送只要求已完成外送必有对应 DELIVERED 行，未完成外送可没有配送。
基线表批次列/快照存储已由C冻结；B已据其协议提供baseline_b五表53列，不另设采集入口或批次格式。

## 4. 依赖矩阵与交接

| B 改动点（若发生） | 本域消费者 | 外域消费者 | 先决动作 |
| --- | --- | --- | --- |
| 明细角色、父键、数量或列名 | sp_create_order、厨房/详情、种子/验收 | C lock/consume、联查；A 销量/BOM展示相关分析 | B 提出兼容方式，C 审核库存展开后再删兼容列 |
| total_amount 移除/派生 | pay、cancel/refund、v_order_detail、应用金额读取 | C 基线汇总；A 销量需确认自身口径 | 冻结等价聚合与接口，不先删列 |
| point_delta / 积分快照改动 | pay、pickup、confirm、积分视图 | A 入账参数；C 回归汇总 | 保持 sp_apply_customer_points 协议或同步冻结新约定 |
| rider FK 或配送键 | rider 两过程、Delivery | C 身份/授权/已有 FK | B 持有子表迁移；C 提供既有约束材料 |
| 新岗位查询 | B 查询过程、Orders DAO | C GRANT/白名单；A 应用契约 | B 给参数、列类型/可空性和岗位；A/C 汇总冻结后纳入 11b/11c/12 |

C 默认入口顺序 11a→11b→11c→12 只在依赖矩阵可满足时使用；若 A 删除 C 尚用对象，必须冻结改序或分域 finalize，不能靠运行时报错试探。
B 新错误码由 C 登记；B 不改 12_permissions、Common、Auth、全组问题表状态。

## 5. 迁移执行与验收门

以下为共同冻结后的迁移要求；本轮仅提前实现已冻结协议的baseline_b并在独立夹具库验证，没有运行11b或v1.0迁移：

1. 2.1 收口、OI-03 冻结；A/C 范式分析齐备，A 应用数据库契约与 C 迁移/基线协议完成。
2. 停写、备份、采集完整基线；C 预检版本、现场对象/数据与批次，拒绝漂移。
3. B 的 11b 只处理冻结的本域对象；无结构改动也要校验并报告保留，不重跑 create-once 的 02/05/07b；不得 COMMIT 外层事务。
4. 在 C 单连接迁移事务中升级所有调用者后，C 完成授权、签名及事务内只读不变量检查，再提交版本。
5. 迁移事务提交后执行 13b 回归，覆盖合法写入、非法 FK/数量、重复动作、岗位越权和跨域回滚；C 汇总实际分母。用例见[事务规范](transaction-boundaries.md)。
6. 提交前失败验证完整回滚，提交后失败按 C 恢复流程停用并切换已验证副本，绝不删共享库重建。

## 6. 可交接与不可宣称

B 的问题、子图、35 条外键映射和分析材料可供 A 命名/验证、C 合图/需求审查使用。本文不代表已经提供新的数据库过程、不代表 v1.0 迁移通过，也不代表 2.3 应用已开发。

## 7. 三域范式方案汇总（2026-10-24）

来源为[A分析](a-normalization.md)、[B分析](b-normalization.md)、[C分析](c-normalization.md)，只汇总属主提案，不把材料到货等同冻结。v0.1仍为25表；若C拆分获批，v1.0业务表预计26张，辅助表另算，不能继续拿25作新结构固定分母。

| 项 | 目标关系/约束 | 理由与证明 | 迁移归属与负例 |
| --- | --- | --- | --- |
| A：MemberLevel | UQ(threshold_points)，建议UQ(level_name) | 前者把过程保证的门槛唯一声明化；不是拆表 | 11a；输出同门槛/同名冲突，禁止静默去重；13a验证2601/2627 |
| A：Category/Product | 各UQ(name)提案 | 名称业务唯一需确认；没有DDL声明不等于理论FD必不存在 | 11a；先检重名及排序规则影响，保留ID和外键 |
| A：Ingredient | UQ(ingredient_name,unit_name) | 单位是组合键的一部分，不能只以原料名去重 | 11a；相同名不同单位仍合法，B/C继续用ingredient_id |
| B：五表 | 保留键、价格/数量快照、总额、积分事件值 | 历史快照不随当前配置；积分公式保留反规范化见§2与B分析 | 11b未来升级本域接口；13b守卫和逐值对账 |
| C：权限目录 | Permission(permission_code PK,permission_name)；RolePermission(business_role_id,permission_code,status)，原复合PK保留，新增目录FK | 原code→name是对复合码的部分依赖；交集code为Permission码，分解无损；原FD可由投影闭包推出 | 11c；同码多名拒绝，旧授权经连接重建逐行一致，13c验断链/重复 |
| C：PurchaseOrder | UQ(replenishment_suggestion_id) | 业务每建议最多一采购单；补声明而非搬数据 | 11c；重复建议键输出具体单据，不以保留一行修冲突 |

权限目录的46码/52授权是当前种子示例，不是v1.0常量；新增员工查询和顾客过程后数量由冻结清单计算。名称保真基线必须捕获旧RolePermission.permission_name，迁移后用Permission连接回旧关系比较，不能只看授权总数。
2026-10-30接收C最终细则：保留固定枚举CHECK并迁到Permission.permission_code；11c同时ALTER扩展CHECK、插目录行与角色映射，12只核对授权/签名；cust_app三过程不进业务岗位白名单。B不再将此列为C未交，具体11b依赖及六查询授权输入见[B冻结回执](b-freeze-receipt.md) §2。

### 7.1 顾客积分：必须带期初而非从零汇总

A分析§4.1拟直接断言 current_points=SUM(EFFECTIVE.point_delta)，但09a顾客2/3分别预置500/1500，未为这些期初分生成B流水；09b仅为其后订单生成积分。故“完全由本库流水推出”对现有数据不成立，不能用此断言拒绝合法迁移或把顾客余额清零。
采用只读对账关系：opening_offset(customer)=baseline_current_points−SUM(baseline_EFFECTIVE.point_delta)。采集时保存余额、已生效流水和offset，迁移后要求offset及逐笔事实保持；迁移后新业务的余额增量等于本期新生效流水增量。该offset是基线事实，不是擅自新增业务列或虚构期初流水。
若只考虑09a刚完成时点，三顾客期初为0/500/1500；任意现有数据库必须实测采集，不能把这三个数硬套到所有顾客。A需要据此修订13a/基线方案；B不修改A文件。保留累计积分列与保留订单总额分别成立，不靠“必须同取舍”证明。

### 7.2 迁移顺序与冻结清单

仍沿用预检→11a→11b→11c→12→事务内不变量→版本→COMMIT的默认顺序。A新增唯一不删除B/C引用ID；B新顾客/员工查询消费A函数与现表；C最后拆目录、补唯一、扩新权限，12统一授权/签名。若新增依赖使顺序不可满足，先冻结分域finalize，不修改第一阶段源码救运行错误。
2026-10-30收口复核：OI-09已closed；B决策已并入A共同契约，A期初积分修订、C白名单/辅助表协议均已交；B补齐[冻结回执与11b矩阵](b-freeze-receipt.md)，技术上支持2026-11-03建议日期，最终待用户本人确认。OI-03仍由C维护，B不代用户/C签字或替全组关闭；顾客§1联合未定项不随员工§2自动冻结。

八个写入口保持现有签名；六个新员工查询的参数/结果/岗位以共同§2及B矩阵为唯一输入，依赖现有表而非新Permission，因此标准11a→11b→11c→12可行。共享层两结果集与nextset异常问题交A修复，请求身份交C验真；这些关系到应用验收，不应为了赶工跨改A/C源码或提前部署未冻结查询。

## 8. R6-05独立教学示例：传递依赖与无损分解

仅作纸面关系推演，不创建SQL对象、不属于真实商品多分类模型。假设DEMO_ProductFlat(product_id,product_name,category_id,category_name)，人为规定每商品恰有一个分类；FD为product_id→product_name,category_id，category_id→category_name。
例：(1,汉堡,10,主食)、(2,鸡肉卷,10,主食)。无法只登记一个没有商品的分类是插入异常；将一行“主食”改“正餐”但漏另一行是修改异常；删除最后一件分类10商品导致分类名称一起丢失是删除异常。
分解DEMO_Product(product_id PK,product_name,category_id)与DEMO_Category(category_id PK,category_name)：公共属性category_id是后者超码，故二元分解无损；两条FD分别落在分表，product_id→category_name由传递可推出，故依赖保持。两商品连接回分类恰还原两行，没有伪元组。
此示例靠明确FD而非两行巧合证明。真实ProductCategory是M:N，product_id并不决定唯一category_id，不能据此教学示例合并/强拆真实表。v1.0不创建DEMO_*业务表。
