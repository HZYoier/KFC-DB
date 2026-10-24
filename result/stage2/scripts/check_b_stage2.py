"""Read-only B stage-2 document/schema reconciliation. No DB connection or writes.

Run: python -I result/stage2/scripts/check_b_stage2.py --self-test
Structural checks are not SQL/application acceptance or proof of normalization.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
B_DOCS = [
    'b-issues.md', 'b-normalization.md', 'b-interface-handoff.md',
    'b-baseline-reconciliation.md', 'b-test-cases.md', 'b-stage-report.md',
    'b-duplicate-product-decision.md', 'b-contract-decisions.md',
    'b-customer-test-cases.md', 'business-rule-mapping.md',
    'refactoring-design.md', 'transaction-boundaries.md',
]


def validate(overrides=None):
    overrides = overrides or {}
    results = []

    def read(path):
        return overrides[path] if path in overrides else (ROOT / path).read_text(encoding='utf-8-sig')

    def check(ok, label):
        results.append((bool(ok), label))

    docs = {name: read('docs/stage2/' + name) for name in B_DOCS}
    schema = read('sql/02_order_schema.sql')
    draw = ET.fromstring(read('docs/er/b-order.drawio'))
    svg = ET.fromstring(read('docs/er/b-order.svg'))
    cells = {c.attrib['id']: c for c in draw.iter('mxCell')}
    column_count = 0
    tables = re.findall(r'CREATE TABLE dbo\.(\w+)\s*\((.*?)\n\s*\);', schema, re.S | re.I)
    check(len(tables) == 5, 'five B tables')
    for name, body in tables:
        cols = re.findall(r'^\s*(\w+)\s+(BIGINT|VARCHAR\(\d+\)|INT|DECIMAL\(\d+,\d+\)|DATETIME2\(\d+\))([^\n]*)', body, re.M)
        cell = cells.get(name)
        check(cell is not None, 'draw entity ' + name)
        base = re.search(r'### ' + name + r'：(.*?)(?=\n### |\n## 3\.)', docs['b-baseline-reconciliation.md'], re.S)
        for col, typ, rest in cols:
            nullable = '否' if 'NOT NULL' in rest else '是'
            expected = '| ' + col + ' | ' + typ + ' | ' + nullable + ' |'
            check(base is not None and expected in base.group(), 'baseline ' + name + '.' + col)
            label = '' if cell is None else cell.attrib.get('value', '')
            check(re.search(r'\b' + col + r'\b', label) is not None, 'draw column ' + name + '.' + col)
            group = next((g for g in svg.iter() if g.attrib.get('id') == name), None)
            check(group is not None and any(x.attrib.get('data-column') == col for x in group), 'svg column ' + name + '.' + col)
        column_count += len(cols)
    check(column_count == 53, '53 B columns')
    fk_names = []
    for file in ['01_master_schema.sql', '02_order_schema.sql', '03_inventory_security_schema.sql']:
        fk_names += re.findall(r'CONSTRAINT\s+(FK_\w+)\s+FOREIGN\s+KEY', read('sql/' + file), re.I)
    check(len(fk_names) == 35, '35 physical FKs in source')
    for name in fk_names:
        check(docs['business-rule-mapping.md'].count(name) == 1, 'FK mapping ' + name)
    edges = [c for c in cells.values() if c.attrib.get('edge') == '1']
    check(len(edges) == 10, '10 B graph edges')
    for c in edges:
        name = c.attrib['id']
        check(name in fk_names, 'declared graph FK ' + name)
        optional = name in {'FK_SalesOrderItem_Parent', 'FK_SalesOrderItem_Promotion', 'FK_Delivery_RiderEmployee'}
        unique = name in {'FK_Payment_SalesOrder', 'FK_Delivery_SalesOrder', 'FK_PointLedger_SalesOrder'}
        style = c.attrib.get('style', '')
        check(('startArrow=' + ('ERzeroToOne' if optional else 'ERone') + ';') in style, 'parent endpoint ' + name)
        check(('endArrow=' + ('ERzeroToOne' if unique else 'ERzeroToMany') + ';') in style, 'child endpoint ' + name)
        check(any(x.attrib.get('id') == name for x in svg.iter()), 'SVG FK ' + name)
    norm = lambda s: re.sub(r'\s+', ' ', s).strip()
    src = read('sql/05_order_constraints_crud.sql')
    procs = re.findall(r'CREATE PROCEDURE dbo\.(\w+)\s+(.*?)\nAS\b(.*?)(?=\nGO\b)', src, re.S | re.I)
    check(len(procs) == 8, 'eight write procedures')
    handoff = docs['b-interface-handoff.md']
    for name, params, body in procs:
        section = re.search(r'### ' + name + r'\n(.*?)(?=\n### |\n## 2\.)', handoff, re.S)
        block = None if section is None else re.search(r'```sql\n' + name + r'\n(.*?)\n```', section.group(), re.S)
        check(block is not None and norm(block.group(1)) == norm(params), 'signature ' + name)
        for code, message in re.findall(r"THROW\s+(\d+),\s*'([^']*)'", body):
            check(section is not None and '| ' + code + ' | ' + message + ' |' in section.group(), 'error ' + name + ':' + code)
    for name, contents in docs.items():
        for target in re.findall(r'\]\(([^)]+)\)', contents):
            if target.startswith(('http://', 'https://', '#')):
                continue
            check((ROOT / 'docs/stage2' / target.split('#')[0]).exists(), 'local link ' + name + ':' + target)
    for i in range(1, 12):
        check(re.search(r'^## \d+\. BT-' + f'{i:02d}' + r'\b', docs['b-test-cases.md'], re.M) is not None, 'BT group ' + str(i))
    for i in range(1, 9):
        check('| CG-' + f'{i:02d}' in docs['b-customer-test-cases.md'], 'CG group ' + str(i))
    decisions = docs['b-contract-decisions.md']
    for phrase in ['OI-09', '待决一', '待决二', '待决三', '不新增第四个', 'UPDLOCK', 'HOLDLOCK', '53000', 'DELIVERY']:
        check(phrase in decisions, 'decision coverage ' + phrase)
    check('opening_offset' in docs['refactoring-design.md'], 'opening offset in refactoring')
    check('RolePermission(business_role_id,permission_code,status)' in docs['refactoring-design.md'], 'exact C mapping key in summary')
    check('None' in docs['transaction-boundaries.md'], 'Python NULL binding')
    return results


def main():
    results = validate()
    if '--self-test' in sys.argv:
        mutations = [
            ('signature mismatch', 'docs/stage2/b-interface-handoff.md', lambda s: s.replace('@customer_id BIGINT', '@customer_id INT', 1)),
            ('missing column', 'docs/stage2/b-baseline-reconciliation.md', lambda s: s.replace('| total_amount | DECIMAL(10,2)', '| removed_column | DECIMAL(10,2)', 1)),
            ('missing FK', 'docs/stage2/business-rule-mapping.md', lambda s: s.replace('FK_SalesOrder_Customer', 'REMOVED_FK', 1)),
            ('broken link', 'docs/stage2/b-issues.md', lambda s: s + '\n[missing](__missing_b_check__.md)\n'),
            ('wrong endpoint', 'docs/er/b-order.drawio', lambda s: s.replace('startArrow=ERone;', 'startArrow=ERzeroToMany;', 1)),
        ]
        for label, path, mutate in mutations:
            source = (ROOT / path).read_text(encoding='utf-8-sig')
            altered = mutate(source)
            failures = [name for ok, name in validate({path: altered}) if not ok]
            results.append((source != altered and bool(failures), 'negative probe: ' + label))
    for ok, label in results:
        print(('PASS ' if ok else 'FAIL ') + label)
    passed = sum(ok for ok, _ in results)
    failed = len(results) - passed
    print(f'RESULT: pass={passed} fail={failed} total={len(results)}')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
