# B 订单工作台运行截图（2026-11-09）

图 02–08 为红白版 B 订单工作台。图 01 重新截取的是 C 的共用登录入口，样式保持原样。

## 环境

- 实例：本机 SQL Server `localhost\MSSQLSERVER2`。从空的临时库部署 v0.1，采集三域基线，再迁移到 v1.0。
- 账号：收银、厨师、配餐、叫号、骑手和店长各用一个临时 SQL 登录。登录截图未填写账号或口令；截图中的订单号和取餐码都来自临时测试数据。
- 方法：用 Flask 测试客户端获取真实页面，再用 Edge 无头模式以 1440 像素宽渲染。支付详情页完整保留了售卖明细和付款表单；骑手页另走了两张演示外送单，分别保留在待认领和配送中。

## 文件

| 截图 | 页面里能看到什么 |
| --- | --- |
| [01 员工登录](b-orders-ui-01-login.png) | 共用的员工登录入口 |
| [02 收银下单](b-orders-ui-02-cashier.png) | 新客登记、选品、下单前生成的订单号 |
| [03 支付详情](b-orders-ui-03-payment.png) | 待支付订单、订单头、售卖明细和支付表单 |
| [04 厨师队列](b-orders-ui-04-chef.png) | 已支付订单和开始制作入口 |
| [05 配餐队列](b-orders-ui-05-packer.png) | 制作中的订单、商品明细和完成制作入口 |
| [06 取餐叫号](b-orders-ui-06-waiter.png) | 同一笔自取单变为待取餐，并显示取餐码 |
| [07 骑手工作台](b-orders-ui-07-rider.png) | 一笔待认领订单和一笔已归当前骑手的配送单 |
| [08 店长工作台](b-orders-ui-08-store-manager.png) | 订单号查询及取消订单入口 |

## 复跑与边界

在仓库根目录执行 [截图脚本](capture.py)。脚本使用现有 B 联调入口，只会创建并清理本次的隔离库和临时账号。

```powershell
.venv\Scripts\python.exe -X utf8 result/stage2/b-orders-ui/capture.py --sql-server 'localhost\MSSQLSERVER2' --edge 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
```

截图说明真实数据库连接下的页面显示情况，不能单独证明所有按钮或越权分支都已验收。业务断言和回滚结果见 [实验记录](../b-migration-and-orders-2026-11-08.txt)。
