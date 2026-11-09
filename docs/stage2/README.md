# 第二阶段文档索引

> 属主：A（本索引）。正文的属主按各文件头部的声明，改写前先确认不越界。
> 本目录是第二阶段的全部过程文档；阶段报告单独收在 [`reports/`](reports/)，其余按用途分五组。

## 先看这几份

| 顺序 | 文档 | 属主 | 说明 |
| --- | --- | --- | --- |
| 1 | [A 阶段报告](reports/a-stage2-report.md) | A | 主数据、定价与会员：迁移、应用层、九实体页面与 12 张运行截图 |
| 2 | [B 阶段报告](reports/b-stage2-report.md) | B | 订单、支付与履约：`11b`、岗位工作台与 8 张运行截图 |
| 3 | [C 阶段报告](reports/c-stage2-report.md) | C | 迁移、权限、库存与顾客应用 |
| 4 | [测试报告](test-report.md) | C | 全组测试汇总：环境、结果、证据索引 |
| 5 | [操作手册](user-manual.md) | C | 启动、迁移顺序、各岗位与顾客端入口、全部界面的操作步骤 |
| 6 | [迁移指南](migration-guide.md) | C | 采集、迁移、回归的执行顺序与回滚细则 |

## 阶段报告（`reports/`）

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [reports/a-stage2-report.md](reports/a-stage2-report.md) | A | 主数据域迁移与应用落地 |
| [reports/b-stage2-report.md](reports/b-stage2-report.md) | B | 订单、支付与履约 |
| [reports/c-stage2-report.md](reports/c-stage2-report.md) | C | 迁移、权限、库存与顾客应用 |
| [b-stage-report.md](b-stage-report.md) | B | **旧名报告，留在本级**：B 的阶段 1 式报告，被 B 自己的三份交接文档与 `result/stage2/scripts/check_b_stage2.py` 按原名引用，故不随其余三份迁入 `reports/` |

## 接口与契约

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [application-contract.md](application-contract.md) | A | 第二阶段跨域接口契约：§2 八个写接口与六个查询接口（冻结）、§2.4 四个查询/登记接口、§1 顾客端联合边界 |
| [access-layer-contract.md](access-layer-contract.md) | A | 访问层 `app/common` 的五个签名、多结果集口径与错误码映射 |
| [business-rule-mapping.md](business-rule-mapping.md) | B | 35 条外键的联系两端基数与实现机制 |
| [transaction-boundaries.md](transaction-boundaries.md) | B | 各过程的事务边界与调用约束 |

## 设计与分析

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [a-normalization.md](a-normalization.md) | A | A 域范式分析（10 表 / 47 列）与三条冻结语义 |
| [b-normalization.md](b-normalization.md) | B | B 域范式分析与表保留 / 拆分结论 |
| [c-normalization.md](c-normalization.md) | C | C 域范式分析与 `Permission` 拆分 |
| [naming.md](naming.md) | A | 命名口径：对象形状、表名与字典对照、偏差登记、跨阶段同名规则 |
| [refactoring-design.md](refactoring-design.md) | B | v0.1 的更新异常与重构方案 |
| [source-requirements.md](source-requirements.md) | C | 三份课程讲解的逐条核对：编号、原文要点、落点与状态 |

## 问题与决议

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [open-issues.md](open-issues.md) | C | **跨域开放问题的唯一状态入口**（OI 编号、状态、决议） |
| [a-issues.md](a-issues.md) | A | A 域逐表问题清单与 I-A08–I-A12 结论 |
| [b-issues.md](b-issues.md) | B | B 域逐表问题清单 |
| [c-issues.md](c-issues.md) | C | C 域逐表问题清单 |
| [b-contract-decisions.md](b-contract-decisions.md) | B | B 对 OI-09 / OI-10 的决策与可直接合入的规则文本 |
| [b-duplicate-product-decision.md](b-duplicate-product-decision.md) | B | 同商品多行与顶层输入的取舍材料（I-B08） |
| [b-freeze-receipt.md](b-freeze-receipt.md) | B | B 的冻结回执、`11b` 依赖矩阵与实际交付回执 |

## 交接与用例（B 域）

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [b-interface-handoff.md](b-interface-handoff.md) | B | 数据库接口交接清单 |
| [b-baseline-reconciliation.md](b-baseline-reconciliation.md) | B | 迁移基线与逐字段对账规范 |
| [b-test-cases.md](b-test-cases.md) | B | 员工侧测试用例与执行规程 |
| [b-customer-test-cases.md](b-customer-test-cases.md) | B | 顾客端与 Flask 补充验收设计 |
| [b-delivery-handoff.md](b-delivery-handoff.md) | B | 交付入口：README 素材、角色范围与接续依据 |

## 流程与规范

| 文件 | 属主 | 说明 |
| --- | --- | --- |
| [migration-guide.md](migration-guide.md) | C | 基线采集、迁移、回归的执行顺序与回滚细则 |
| [user-manual.md](user-manual.md) | C | 启动、七岗位与顾客端入口、全部可用界面的操作步骤 |
| [test-report.md](test-report.md) | C | 第二阶段测试汇总与证据索引 |
| [team-division.md](team-division.md) | C | 团队分工与交接边界 |
| [project-structure.svg](project-structure.svg) | A | 项目结构图：仓库结构 + 运行时分层与调用链 |

## 约定

- 阶段报告只放 `reports/`，新写的按 `<成员>-stage2-report.md` 命名（见 [naming.md](naming.md) §5）。
- 跨域问题一律登记到 [open-issues.md](open-issues.md)，状态列由 C 统一维护；域内问题写各域 `*-issues.md`。
- 新增文档时在本表对应分组补一行，不要另起目录。
