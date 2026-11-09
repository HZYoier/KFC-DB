# C 库存、员工角色与顾客页面截图（2026-11-09）

> 属主：C（库存、补货、员工权限、审计、顾客端与总集成）。本目录只放 C 域页面在真实 v1.0 库上的运行截图，不等于完整联合验收。

## 环境

- 实例：`.\SQLEXPRESS`（SQL Server 2025 Express），`KFC_DB` 已由真实 `run_all → capture_baseline → run_migration` 迁移到 **v1.0**（15 过程 / 3 个 `cust_app` GRANT / 58 码 / 71 行）。
- 账号：截图时临时创建 `c_ui_store`、`c_ui_cust` 两个随机口令 SQL 登录，分别映射到 `test_store_manager` 与 `cust_app`；口令只在内存中，不打印、不入仓。截图后恢复 `test_store_manager`/`cust_app` 为 `WITHOUT LOGIN` 并删除临时登录。
- 数据：库存看板、流水、补货建议、员工角色、顾客订单均来自真实库的测试种子和截图时的顾客下单；订单号、取餐码、手机号都是测试值。
- 截图方式：Flask test client 取得页面 HTML（模板使用内联样式），用 Chrome/Edge headless 以 1440 像素宽渲染 PNG。页面不保存口令或会话 cookie。

## 文件

| 文件 | 页面里能看到什么 |
| --- | --- |
| [01 员工登录](c-inventory-customer-ui-01-login.png) | 数据库登录入口；顾客自助入口 |
| [02 店长身份首页](c-inventory-customer-ui-02-identity-store.png) | 姓名、岗位、业务角色、权限码入口，以及主数据/库存/订单入口 |
| [03 库存看板](c-inventory-customer-ui-03-inventory-dashboard.png) | 现有量/锁定/可售/安全线、库存调整、流水与补货建议/采购 |
| [04 员工角色](c-inventory-customer-ui-04-inventory-roles.png) | 仅有店长可读的员工与业务角色映射 |
| [05 顾客自助](c-inventory-customer-ui-05-customer-home.png) | 建档、下自取单、按手机号+取餐码查单三个表单 |
| [06 顾客下单结果](c-inventory-customer-ui-06-customer-order.png) | 真实下单返回的订单号、取餐码、金额和状态 |
| [07 顾客查单](c-inventory-customer-ui-07-customer-orders.png) | 用手机号 + 上一步取餐码查回同一订单头 |

## 复跑

先准备已迁移到 v1.0 的 `KFC_DB`，然后在仓库根目录：

```powershell
python result/stage2/c-inventory-customer-ui/capture.py `
  --browser "C:/Program Files/Google/Chrome/Application/chrome.exe"
```

`capture.py` 只临时映射 `test_store_manager`/`cust_app`，跑完恢复用户并删除临时登录；不会部署或迁移数据库。

## 边界

- 这组截图证明 C 的登录/身份页、库存页、员工角色页和顾客自助页在真实 v1.0 连接下可以取数与渲染，**不证明** A/B 页面、越权负例、并发、故障回滚或正式员工/顾客 SQL 登录部署。
- 顾客页当前输入商品 ID/数量；本轮没有对顾客开放的商品目录过程，商品 ID 需向店员确认。
- 正式联合验收仍需 A/B/C 用操作者提供的员工/顾客登录做浏览器走查并回执。
