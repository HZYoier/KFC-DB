"""访问层底座：配置、连接与参数绑定、事务、错误码、结构化日志。

域模块（app/master、app/orders、app/inventory、app/auth）只调用这里，
不得自行 import pyodbc、连库、开事务或定义错误码。
"""
