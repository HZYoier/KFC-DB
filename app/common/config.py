"""连接配置的唯一读取点。

凭据只从环境变量取；仓库里只有 config.example.env 的形状，没有真实值。
日志与异常都不得回显口令或完整连接串（计划 §6.3）。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DRIVER = "ODBC Driver 18 for SQL Server"


@dataclass(frozen=True)
class DbConfig:
    driver: str
    server: str
    database: str
    encrypt: str = "yes"
    trust_server_certificate: str = "no"
    query_timeout: int = 30
    trusted_connection: bool = False
    log_level: str = "INFO"

    def connection_string(self) -> str:
        """不含凭据。口令一律作为 pyodbc.connect 的关键字参数传入，避免进日志。"""
        parts = [
            "DRIVER={%s}" % self.driver,
            "SERVER=%s" % self.server,
            "DATABASE=%s" % self.database,
            "Encrypt=%s" % self.encrypt,
            "TrustServerCertificate=%s" % self.trust_server_certificate,
            "APP=KFC_DB",
        ]
        if self.trusted_connection:
            parts.append("Trusted_Connection=yes")
        return ";".join(parts) + ";"


def load_env_file(path: str | Path = ".env") -> None:
    """读 KEY=VALUE 形状的本地文件，不覆盖已存在的环境变量，不引入额外依赖。"""
    p = Path(path)
    if not p.is_file():
        return
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def _flag(value: str | None) -> bool:
    return (value or "").strip().lower() in ("1", "true", "yes", "y")


def load_db_config(env: dict[str, str] | None = None) -> DbConfig:
    """从环境变量装配配置。server 缺失即报错——不猜实例名。"""
    env = os.environ if env is None else env
    server = (env.get("KFC_DB_SERVER") or "").strip()
    if not server:
        raise RuntimeError("未设置 KFC_DB_SERVER：请复制 config.example.env 为 .env 并填本机实例名。")
    return DbConfig(
        driver=(env.get("KFC_DB_DRIVER") or DEFAULT_DRIVER).strip(),
        server=server,
        database=(env.get("KFC_DB_NAME") or "KFC_DB").strip(),
        encrypt=(env.get("KFC_DB_ENCRYPT") or "yes").strip().lower(),
        trust_server_certificate=(env.get("KFC_DB_TRUST_CERT") or "no").strip().lower(),
        query_timeout=int((env.get("KFC_DB_QUERY_TIMEOUT") or "30").strip()),
        trusted_connection=_flag(env.get("KFC_DB_TRUSTED_CONNECTION")),
        log_level=(env.get("KFC_DB_LOG_LEVEL") or "INFO").strip().upper(),
    )
