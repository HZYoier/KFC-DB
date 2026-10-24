# -*- coding: utf-8 -*-
"""A 域规范化分析对账脚本（对应 docs/stage2/a-normalization.md §2 与 §1 统计量）。

用法：python -I check_a_norm.py
判据：输出「0 差异（全部通过）」且退出码 0。
读取：
  sql/01_master_schema.sql            —— A 域 10 表的表名、列名、类型、可空性、主键
  sql/04_master_constraints_crud.sql  —— 命名 CHECK 数量
  docs/stage2/a-normalization.md      —— §2 的属性与键清单
"""
import io
import os
import re
import sys

# Windows 控制台默认 GBK：强制 UTF-8，否则重定向到文件后中文变 GBK 字节
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

SCHEMA = os.path.join(REPO, 'sql', '01_master_schema.sql')
CRUD = os.path.join(REPO, 'sql', '04_master_constraints_crud.sql')
DOC = os.path.join(REPO, 'docs', 'stage2', 'a-normalization.md')

schema = io.open(SCHEMA, encoding='utf-8').read()
crud = io.open(CRUD, encoding='utf-8').read()
doc = io.open(DOC, encoding='utf-8').read()

# ---- §A 从 01 解析表 / 列 / 主键 ----
tables = {}
cur = None
for raw in schema.split('\n'):
    line = raw.split('--')[0]
    m = re.match(r'\s*create table (\w+)\s*\(', line, re.I)
    if m:
        cur = m.group(1)
        tables[cur] = {'cols': [], 'pk': set()}
        continue
    if cur is None:
        continue
    if line.strip().startswith(')'):
        cur = None
        continue
    # 复合主键在独立的 constraint 行上
    if re.match(r'\s*constraint\b', line, re.I):
        m2 = re.search(r'constraint\s+PK_\w+\s+primary key\s*\(([^)]*)\)', line, re.I)
        if m2:
            for c in m2.group(1).split(','):
                tables[cur]['pk'].add(c.strip())
        continue
    # 多行外键定义的第二行（foreign key(...) references ...）不是列定义
    if re.match(r'\s*(foreign|references|primary|unique|check|default)\b', line, re.I):
        continue
    m = re.match(r'\s*\[?(\w+)\]?\s+([a-zA-Z]+\d*(?:\s*\(\s*\d+\s*(?:,\s*\d+\s*)?\))?)(.*)$', line)
    if not m:
        continue
    col, typ, rest = m.group(1), m.group(2), m.group(3)
    if re.search(r'primary key', rest, re.I):
        tables[cur]['pk'].add(col)
    notnull = bool(re.search(r'\bnot\s+null\b', rest, re.I))
    tables[cur]['cols'].append((col, re.sub(r'\s+', '', typ), notnull))

schema_rows = {}
for t, info in tables.items():
    for col, typ, notnull in info['cols']:
        is_null = (not notnull) and (col not in info['pk'])
        schema_rows[(t, col)] = (typ.upper(), is_null)

# ---- §B 从文档 §2 解析清单 ----
doc_rows = {}
for line in doc.split('\n'):
    m = re.match(r'\|\s*`(\w+)`\s*\|\s*`(\w+)`\s*\|\s*`([^`]+)`\s*\|\s*\**\s*(否|是)\s*\**\s*\|', line)
    if m:
        doc_rows[(m.group(1), m.group(2))] = (
            re.sub(r'\s+', '', m.group(3)).upper(), m.group(4) == '是')

# ---- §C 比对 ----
problems = []
for k in sorted(set(schema_rows) - set(doc_rows)):
    problems.append('文档缺少 %s.%s（源码 %s）' % (k[0], k[1], schema_rows[k]))
for k in sorted(set(doc_rows) - set(schema_rows)):
    problems.append('文档多出 %s.%s（文档 %s）' % (k[0], k[1], doc_rows[k]))
for k in sorted(set(schema_rows) & set(doc_rows)):
    if schema_rows[k] != doc_rows[k]:
        problems.append('%s.%s 不一致：源码 (类型, 可空)=%s，文档=%s'
                        % (k[0], k[1], schema_rows[k], doc_rows[k]))

# ---- §D 统计量 ----
checks = re.findall(r'ADD CONSTRAINT (CK_\w+)', crud)
fks = sorted(set(re.findall(r'constraint (FK_\w+)', schema)))
composite_pk = sorted(t for t, info in tables.items() if len(info['pk']) > 1)

print('[A] 源码表数 = %d，列数 = %d，复合主键表 = %d %s'
      % (len(tables), len(schema_rows), len(composite_pk), composite_pk))
print('[A] A 域外键 = %d' % len(fks))
print('[B] 文档 §2 行数 = %d，唯一 (表, 列) = %d' % (len(doc_rows), len(set(doc_rows))))
print('[D] 命名 CHECK = %d（唯一 %d）' % (len(checks), len(set(checks))))
print('[D] 可空列 = %s' % sorted(k[1] for k, v in schema_rows.items() if v[1]))

if len(tables) != 10:
    problems.append('表数不是 10')
if len(schema_rows) != 47:
    problems.append('列数不是 47')
if len(composite_pk) != 3:
    problems.append('复合主键表不是 3 张')
if len(fks) != 9:
    problems.append('A 域外键不是 9 条')
if len(checks) != 22 or len(set(checks)) != 22:
    problems.append('命名 CHECK 不是 22 条')
if [k[1] for k, v in schema_rows.items() if v[1]] != ['member_level_id']:
    problems.append('可空列不止 Customer.member_level_id')

print('[C] 差异 = %d 项' % len(problems))
for p in problems:
    print('   - ' + p)
if not problems:
    print('     0 差异（全部通过）')
sys.exit(1 if problems else 0)
