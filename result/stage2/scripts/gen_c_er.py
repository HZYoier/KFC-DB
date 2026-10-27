# -*- coding: utf-8 -*-
"""生成 C 域 ER 子图：docs/er/c-inventory-security.drawio 与 .svg（同源，布局一致）。
依据：2026-10-13 活库目录实测 + docs/er/legend.md 的符号约定（乌鸦脚）。"""
import html
import math

REPO = r'D:\DBLab\KFC-DB'
BOX_W = 280
HEAD_H = 26
ROW_H = 20
PAD_B = 6

# id: (title, x, y, cols, external)
ENTS = [
    ('E_ING',  'Ingredient（A 域）', 40, 40,
     ['PK ingredient_id', 'ingredient_name', 'status'], True),
    ('E_INV',  'Inventory', 40, 230,
     ['PKFK ingredient_id', 'on_hand_qty', 'locked_qty', 'updated_at'], False),
    ('E_MOV',  'InventoryMovement', 40, 420,
     ['PK inventory_movement_id', 'FK ingredient_id → Inventory', 'movement_type',
      'on_hand_delta', 'locked_delta', 'reference_type', 'reference_id (NULL)', 'moved_at'], False),
    ('E_SUG',  'ReplenishmentSuggestion', 400, 40,
     ['PK replenishment_suggestion_id', 'FK ingredient_id → Ingredient', 'current_qty', 'suggested_qty',
      'suggestion_status', 'FK created_by_employee_id', 'FK submitted_by_employee_id (NULL)',
      'FK approved_by_employee_id (NULL)', 'FK rejected_by_employee_id (NULL)'], False),
    ('E_PO',   'PurchaseOrder', 400, 340,
     ['PK purchase_order_id', 'UK purchase_order_no', 'FK replenishment_suggestion_id',
      'purchase_status', 'FK approved_by_employee_id (NULL)', 'approved_at (NULL)'], False),
    ('E_POI',  'PurchaseOrderItem', 400, 570,
     ['PKFK purchase_order_id', 'PKFK ingredient_id', 'ordered_qty', 'received_qty'], False),
    ('E_EA',   'EmployeeAccount', 780, 40,
     ['PK employee_id', 'UK database_user_name', 'UK login_name', 'employee_name', 'job_code', 'status'], False),
    ('E_BR',   'BusinessRole', 780, 300,
     ['PK business_role_id', 'UK role_code', 'role_name', 'status'], False),
    ('E_RP',   'RolePermission', 780, 480,
     ['PKFK business_role_id', 'PK permission_code', 'permission_name', 'status'], False),
    ('E_EBR',  'EmployeeBusinessRole', 1140, 40,
     ['PKFK employee_id', 'PKFK business_role_id', 'FK assigned_by_employee_id', 'assigned_at'], False),
    ('E_DLV',  'Delivery（B 域）', 1140, 300,
     ['PK delivery_id', 'FK order_id → SalesOrder（B 域，略）', 'FK rider_employee_id (NULL)',
      'delivery_status'], True),
    ('E_AL',   'AuditLog', 1140, 580,
     ['PK audit_log_id', 'FK employee_id → EmployeeAccount', 'action_name', 'entity_name',
      'entity_id (NULL)', 'detail_json (NULL)', 'logged_at'], False),
]

# src, dst, startArrow(在 src 端), endArrow(在 dst 端), label, dashed
EDGES = [
    ('E_ING', 'E_INV', 'ERone', 'ERzeroToOne', '1:1 共享标识（PKFK）；原料可暂无库存行', False),
    ('E_INV', 'E_MOV', 'ERone', 'ERzeroToMany', '1:N 每笔流水必挂库存行', False),
    ('E_ING', 'E_SUG', 'ERone', 'ERzeroToMany', '1:N 历史建议；开放至多一条', False),
    ('E_ING', 'E_POI', 'ERone', 'ERzeroToMany', '1:N 明细引用原料', False),
    ('E_SUG', 'E_PO',  'ERone', 'ERzeroToMany', '审批生成；业务至多一张', False),
    ('E_PO',  'E_POI', 'ERone', 'ERzeroToMany', '结构 0..N；业务恰好 1 条（过程保证）', False),
    ('E_BR',  'E_RP',  'ERone', 'ERzeroToMany', '1:N 权限条目；码受白名单 CHECK', False),
    ('E_EA',  'E_EBR', 'ERone', 'ERzeroToMany', '1:N 员工持有（M:N 关联实体）', False),
    ('E_BR',  'E_EBR', 'ERone', 'ERzeroToMany', '1:N 角色被持有', False),
    ('E_EA',  'E_EBR', 'ERone', 'ERzeroToMany', 'assigned_by（第二外码）', True),
    ('E_EA',  'E_SUG', 'ERone', 'ERzeroToMany', 'created_by 等 4 条员工外码', False),
    ('E_EA',  'E_PO',  'ERzeroToOne', 'ERzeroToMany', 'approved_by（可空）', False),
    ('E_EA',  'E_DLV', 'ERzeroToOne', 'ERzeroToMany', 'rider（可空，认领时写入）', False),
    ('E_EA',  'E_AL',  'ERone',      'ERzeroToMany', '1:N 审计条目', False),
]

# 折线走线（避开实体盒）：pts = 折点序列；label_at = 标签位置；exit/entry = drawio 的相对锚点
WAYPOINTS = {
    ('E_EA', 'E_AL'): {
        'pts': [(1060, 160), (1470, 160), (1470, 666), (1420, 666)],
        'label_at': (1452, 420), 'exit': (1, 0.79), 'entry': (1, 0.5)},
    ('E_ING', 'E_POI'): {
        'pts': [(232, 132), (345, 132), (345, 590), (400, 590)],
        'label_at': (348, 361), 'exit': (0.686, 1), 'entry': (0, 0.182)},
}

TITLE = ('C 域（库存 · 补货 · 权限）ER 子图 — v0.1（依据 2026-10-13 活库目录核对；'
         '2026-10-15 域属主订正：Ingredient 归 A、AuditLog 归 C，OI-06；'
         '2026-10-27 OI-09 结构口径：r6 从端改 0..N；符号图例见 docs/er/legend.md）')
LEGEND = [
    '端点符号：| = 恰好 1    o| = 零或 1    |< = 一或多    o< = 零或多',
    '灰色矩形 = 跨域实体（仅列键列与少量判别列）；虚线 = 同一对实体间的第二条外码',
    '文字标签 = 两端基数（结构口径）— 实现机制/业务说明；业务附加见标签与 business-rule-mapping.md',
]


def ent_height(e):
    return HEAD_H + len(e[4]) * ROW_H + PAD_B


def center(e):
    return (e[2] + BOX_W / 2, e[3] + ent_height(e) / 2)


def clip_to_rect(cx, cy, tx, ty, x, y, w, h):
    """从 (cx,cy) 指向 (tx,ty) 的射线与矩形 (x,y,w,h) 边界的交点。"""
    dx, dy = tx - cx, ty - cy
    best = None
    ts = []
    if dx != 0:
        for bx in (x, x + w):
            t = (bx - cx) / dx
            if t > 0:
                py = cy + t * dy
                if y - 0.5 <= py <= y + h + 0.5:
                    ts.append(t)
    if dy != 0:
        for by in (y, y + h):
            t = (by - cy) / dy
            if t > 0:
                px = cx + t * dx
                if x - 0.5 <= px <= x + w + 0.5:
                    ts.append(t)
    t = min(ts)
    return (cx + t * dx, cy + t * dy)


def esc(s):
    return html.escape(s, quote=True)


def gen_drawio():
    cells = ['  <mxCell id="0" />', '  <mxCell id="1" parent="0" />']
    for eid, title, x, y, cols, external in ENTS:
        h = HEAD_H + len(cols) * ROW_H + PAD_B
        fill = '#f5f5f5' if external else '#dae8fc'
        stroke = '#999999' if external else '#6c8ebf'
        rows = ''.join('<br>{}'.format(c) for c in cols)
        value = '<b>{}</b>{}'.format(title, rows)
        style = ('rounded=0;whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacingLeft=8;'
                 'spacingTop=4;fontSize=12;fillColor={};strokeColor={};').format(fill, stroke)
        cells.append('  <mxCell id="{}" value="{}" style="{}" vertex="1" parent="1">'
                     .format(eid, esc(value), style))
        cells.append('    <mxGeometry x="{}" y="{}" width="{}" height="{}" as="geometry" />'
                     .format(x, y, BOX_W, h))
        cells.append('  </mxCell>')
    idx = 0
    for src, dst, sa, ea, label, dashed in EDGES:
        idx += 1
        style = ('html=1;endArrow={};startArrow={};endFill=0;startFill=0;fontSize=11;'
                 'labelBackgroundColor=#ffffff;').format(ea, sa)
        if dashed:
            style += 'dashed=1;'
        geom = '    <mxGeometry relative="1" as="geometry" />'
        wp = WAYPOINTS.get((src, dst))
        if wp:
            ex, ey = wp['exit']
            nx, ny = wp['entry']
            style += ('exitX={};exitY={};entryX={};entryY={};edgeStyle=orthogonalEdgeStyle;'
                      .format(ex, ey, nx, ny))
            wp_xml = ''.join('<mxPoint x="{}" y="{}" />'.format(px, py)
                             for px, py in wp['pts'][1:-1])
            geom = ('    <mxGeometry relative="1" as="geometry"><Array as="points">{}</Array>'
                    '</mxGeometry>'.format(wp_xml))
        cells.append('  <mxCell id="r{}" value="{}" style="{}" edge="1" parent="1" source="{}" target="{}">'
                     .format(idx, esc(label), style, src, dst))
        cells.append(geom)
        cells.append('  </mxCell>')
    # 标题与图例
    cells.append('  <mxCell id="title" value="{}" style="text;html=1;align=left;verticalAlign=top;fontSize=13;fontStyle=1;" vertex="1" parent="1">'.format(esc(TITLE)))
    cells.append('    <mxGeometry x="40" y="800" width="1200" height="24" as="geometry" />')
    cells.append('  </mxCell>')
    legend_val = '<br>'.join(LEGEND)
    cells.append('  <mxCell id="legend" value="{}" style="text;html=1;align=left;verticalAlign=top;fontSize=11;" vertex="1" parent="1">'.format(esc(legend_val)))
    cells.append('    <mxGeometry x="40" y="832" width="1200" height="72" as="geometry" />')
    cells.append('  </mxCell>')
    body = '\n'.join(cells)
    xml = ('<mxGraphModel dx="1422" dy="798" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
           'arrows="1" fold="1" page="1" pageScale="1" pageWidth="1600" pageHeight="960" math="0" shadow="0">\n'
           '<root>\n{}\n</root>\n</mxGraphModel>\n').format(body)
    return xml


def svg_marker(parts, px, py, dx, dy, kind):
    """在点 (px,py) 处以方向 (dx,dy)（指向实体盒）画端点符号。"""
    L = max(1e-6, math.hypot(dx, dy))
    ux, uy = dx / L, dy / L
    qx, qy = px - ux * 16, py - uy * 16  # 脚踝/刻线基准
    perp = (-uy, ux)
    def line(x1, y1, x2, y2, w=1.2):
        parts.append('<line x1="{:.1f}" y1="{:.1f}" x2="{:.1f}" y2="{:.1f}" stroke="#333" stroke-width="{}"/>'.format(x1, y1, x2, y2, w))
    if kind in ('ERone', 'ERzeroToOne'):
        line(px + perp[0] * 8, py + perp[1] * 8, px - perp[0] * 8, py - perp[1] * 8)
    if kind in ('ERzeroToOne', 'ERzeroToMany'):
        cx, cy = px - ux * (22 if 'Many' in kind else 11), py - uy * (22 if 'Many' in kind else 11)
        parts.append('<circle cx="{:.1f}" cy="{:.1f}" r="4.5" fill="#fff" stroke="#333" stroke-width="1.2"/>'.format(cx, cy))
    if kind == 'ERoneToMany':
        line(qx + perp[0] * 8, qy + perp[1] * 8, qx - perp[0] * 8, qy - perp[1] * 8)
    if kind in ('ERoneToMany', 'ERzeroToMany'):
        for s in (-1, 0, 1):
            tx = px + perp[0] * 8 * s
            ty = py + perp[1] * 8 * s
            line(qx, qy, tx, ty)


def gen_svg():
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="940" viewBox="0 0 1500 940" font-family="Segoe UI, Microsoft YaHei, sans-serif">',
             '<rect x="0" y="0" width="1500" height="940" fill="#ffffff"/>']
    labels = []  # 最后统一画，保证不被实体盒盖住
    point_overrides = {('E_EA', 'E_EBR', True): ((935, 190), (1225, 150))}  # 第二条外码：错开实线
    label_offsets = {('E_ING', 'E_SUG', False): (-20, 0), ('E_EA', 'E_SUG', False): (-30, 0)}
    for src, dst, sa, ea, label, dashed in EDGES:
        se = next(e for e in ENTS if e[0] == src)
        de = next(e for e in ENTS if e[0] == dst)
        wp = WAYPOINTS.get((src, dst))
        if wp:
            pts = wp['pts']
            dash = ' stroke-dasharray="6,4"' if dashed else ''
            for i in range(len(pts) - 1):
                parts.append('<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="#333" stroke-width="1.2"{} />'
                             .format(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], dash))
            svg_marker(parts, pts[0][0], pts[0][1], pts[0][0] - pts[1][0], pts[0][1] - pts[1][1], sa)
            svg_marker(parts, pts[-1][0], pts[-1][1], pts[-1][0] - pts[-2][0], pts[-1][1] - pts[-2][1], ea)
            labels.append((wp['label_at'][0], wp['label_at'][1], label))
            continue
        ov = point_overrides.get((src, dst, dashed))
        if ov:
            p1, p2 = ov
            # 两端都在盒子的下边缘：端点符号一律垂直指向盒内（0,-1）
            svg_marker(parts, p1[0], p1[1], 0, -1, sa)
            svg_marker(parts, p2[0], p2[1], 0, -1, ea)
        else:
            scx, scy = center(se)
            dcx, dcy = center(de)
            p1 = clip_to_rect(scx, scy, dcx, dcy, se[2], se[3], BOX_W, ent_height(se))
            p2 = clip_to_rect(dcx, dcy, scx, scy, de[2], de[3], BOX_W, ent_height(de))
            svg_marker(parts, p1[0], p1[1], scx - dcx, scy - dcy, sa)
            svg_marker(parts, p2[0], p2[1], dcx - scx, dcy - scy, ea)
        dash = ' stroke-dasharray="6,4"' if dashed else ''
        parts.append('<line x1="{:.1f}" y1="{:.1f}" x2="{:.1f}" y2="{:.1f}" stroke="#333" stroke-width="1.2"{} />'.format(p1[0], p1[1], p2[0], p2[1], dash))
        lox, loy = label_offsets.get((src, dst, dashed), (0, 0))
        labels.append(((p1[0] + p2[0]) / 2 + lox, (p1[1] + p2[1]) / 2 + loy, label))
    for eid, title, x, y, cols, external in ENTS:
        h = HEAD_H + len(cols) * ROW_H + PAD_B
        fill = '#f5f5f5' if external else '#dae8fc'
        stroke = '#999999' if external else '#6c8ebf'
        parts.append('<rect x="{}" y="{}" width="{}" height="{}" rx="0" fill="{}" stroke="{}" stroke-width="1.5"/>'.format(x, y, BOX_W, h, fill, stroke))
        parts.append('<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{}" stroke-width="1"/>'.format(x, y + HEAD_H, x + BOX_W, y + HEAD_H, stroke))
        parts.append('<text x="{}" y="{}" font-size="13" font-weight="bold" fill="#1a1a1a">{}</text>'.format(x + 8, y + 17, esc(title)))
        for i, c in enumerate(cols):
            parts.append('<text x="{}" y="{}" font-size="11.5" fill="#333">{}</text>'.format(x + 10, y + HEAD_H + 15 + i * ROW_H, esc(c)))
    # 最后画联系标签（白底、置顶，避免被实体盒盖住）
    for mx, my, label in labels:
        wpx = len(label) * 7.2 + 10
        parts.append('<rect x="{:.1f}" y="{:.1f}" width="{:.1f}" height="16" fill="#ffffff" opacity="0.92"/>'.format(mx - wpx / 2, my - 8, wpx))
        parts.append('<text x="{:.1f}" y="{:.1f}" font-size="11" fill="#444" text-anchor="middle">{}</text>'.format(mx, my + 4, esc(label)))
    parts.append('<text x="40" y="815" font-size="13" font-weight="bold" fill="#1a1a1a">{}</text>'.format(esc(TITLE)))
    for i, l in enumerate(LEGEND):
        parts.append('<text x="40" y="842" font-size="11" fill="#444">{}</text>'.format(esc(l)) if i == 0 else
                     '<text x="40" y="{}" font-size="11" fill="#444">{}</text>'.format(842 + i * 17, esc(l)))
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'


drawio = gen_drawio()
svg = gen_svg()
for path, content in [(REPO + r'\docs\er\c-inventory-security.drawio', drawio),
                      (REPO + r'\docs\er\c-inventory-security.svg', svg)]:
    with open(path, 'wb') as f:
        f.write(content.replace('\n', '\r\n').encode('utf-8'))
    print('written:', path, '| bytes:', len(content.replace('\n', '\r\n').encode('utf-8')))
print('实体数:', len(ENTS), '| 联系数:', len(EDGES))
