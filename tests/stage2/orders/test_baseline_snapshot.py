"""Execute B snapshot SQL in a uniquely owned temporary database; never alter KFC_DB.

Set B_TEST_SQL_SERVER to opt in. Tests use Windows auth. The test database name
is validated; cleanup can only drop the database created by this test instance.
"""
import os
from pathlib import Path
import re
import sys
import unittest
import uuid
from unittest.mock import patch
from decimal import Decimal
from datetime import datetime

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
SCRIPT = ROOT / 'sql/stage2/baseline_b.sql'


class BaselineSnapshotTests(unittest.TestCase):
    @unittest.skipUnless(os.getenv('B_TEST_SQL_SERVER'), 'live SQL baseline test requires B_TEST_SQL_SERVER')
    def test_rows_types_nulls_batch_immutability_permissions_and_outer_rollback(self):
        self.assertTrue(SCRIPT.exists(), 'B baseline snapshot implementation is missing')
        import pyodbc
        server = os.environ['B_TEST_SQL_SERVER']
        name = 'KFC_B_TEST_20261030_' + uuid.uuid4().hex[:12]
        self.assertRegex(name, r'^KFC_B_TEST_20261030_[a-f0-9]{12}$')
        base = 'DRIVER={ODBC Driver 18 for SQL Server};SERVER='+server+';Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;'
        admin = pyodbc.connect(base+'DATABASE=master;', autocommit=True)
        created, conn = False, None
        try:
            admin.execute('CREATE DATABASE ['+name+']')
            created = True
            conn = pyodbc.connect(base+'DATABASE='+name+';', autocommit=True)
            schema = (ROOT/'sql/02_order_schema.sql').read_text(encoding='utf-8-sig')
            fixtures = {}
            for table, body in re.findall(r'CREATE TABLE dbo\.(\w+)\s*\((.*?)\n\s*\);', schema, re.S):
                columns = re.findall(r'^\s*(\w+)\s+(BIGINT|VARCHAR\(\d+\)|INT|DECIMAL\(\d+,\d+\)|DATETIME2\(\d+\))([^\n]*)', body, re.M)
                definitions = [col+' '+typ+(' NOT NULL' if 'NOT NULL' in tail else ' NULL') for col,typ,tail in columns]
                conn.execute('CREATE TABLE dbo.'+table+' ('+', '.join(definitions)+')')
                values = []
                for col, typ, tail in columns:
                    if 'NOT NULL' not in tail:
                        value = None
                    elif typ == 'BIGINT' or typ == 'INT':
                        value = 1
                    elif typ.startswith('DECIMAL'):
                        value = Decimal('1.25') if '5,2' in typ else Decimal('24.10')
                    elif typ.startswith('DATETIME'):
                        value = datetime(2026,10,30,12,0,0)
                    else:
                        value = 'FIXTURE'
                    values.append(value)
                conn.execute('INSERT dbo.'+table+' VALUES ('+','.join('?' for _ in values)+')', values)
                fixtures[table] = (columns, values)
            sql = SCRIPT.read_text(encoding='utf-8-sig')
            conn.execute('CREATE USER b_baseline_probe WITHOUT LOGIN;')
            conn.execute('BEGIN TRANSACTION; DECLARE @batch_id BIGINT=101;\n'+sql)
            self.assertEqual(conn.execute('SELECT @@TRANCOUNT').fetchval(), 1)
            for table, (columns, values) in fixtures.items():
                row = conn.execute('SELECT * FROM dbo.Baseline_'+table+' WHERE batch_id=101').fetchone()
                self.assertEqual(tuple(row), (101, *values), table)
                actual = conn.execute("SELECT c.name,TYPE_NAME(c.user_type_id),c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity FROM sys.columns c WHERE c.object_id=OBJECT_ID(?) ORDER BY c.column_id", 'dbo.Baseline_'+table).fetchall()
                source = conn.execute("SELECT c.name,TYPE_NAME(c.user_type_id),c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity FROM sys.columns c WHERE c.object_id=OBJECT_ID(?) ORDER BY c.column_id", 'dbo.'+table).fetchall()
                self.assertEqual([tuple(x) for x in actual[1:]], [tuple(x) for x in source], table+' types')
            conn.execute('COMMIT TRANSACTION;')
            denial_count = conn.execute("SELECT COUNT(*) FROM sys.database_permissions p JOIN sys.objects o ON o.object_id=p.major_id WHERE o.name LIKE 'Baseline[_]%' AND p.grantee_principal_id=DATABASE_PRINCIPAL_ID('public') AND p.state='D' AND p.permission_name IN ('SELECT','INSERT','UPDATE','DELETE')").fetchval()
            self.assertEqual(denial_count, 20)
            # New batch works; old completed values remain stable even after source changes.
            conn.execute("UPDATE dbo.SalesOrder SET total_amount=99.99")
            conn.execute('BEGIN TRANSACTION; DECLARE @batch_id BIGINT=102;\n'+sql)
            self.assertEqual(conn.execute('SELECT total_amount FROM dbo.Baseline_SalesOrder WHERE batch_id=101').fetchval(), Decimal('24.10'))
            self.assertEqual(conn.execute('SELECT total_amount FROM dbo.Baseline_SalesOrder WHERE batch_id=102').fetchval(), Decimal('99.99'))
            conn.execute('ROLLBACK TRANSACTION;')
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM dbo.Baseline_SalesOrder WHERE batch_id=102').fetchval(), 0)
            conn.execute('DELETE dbo.Payment;')
            conn.execute('BEGIN TRANSACTION; DECLARE @batch_id BIGINT=103;\n'+sql)
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM dbo.Baseline_Payment WHERE batch_id=103').fetchval(), 0)
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM dbo.Baseline_Payment WHERE batch_id=101').fetchval(), 1)
            conn.execute('ROLLBACK TRANSACTION;')
            # Reusing a batch fails rather than overwriting.
            try:
                with self.assertRaises(pyodbc.Error):
                    conn.execute('BEGIN TRANSACTION; DECLARE @batch_id BIGINT=101;\n'+sql)
            finally:
                conn.execute('IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;')
            conn.execute("EXECUTE AS USER='b_baseline_probe';")
            try:
                with self.assertRaises(pyodbc.Error) as denied:
                    conn.execute('SELECT * FROM dbo.Baseline_SalesOrder')
                self.assertIn('(229)', str(denied.exception))
            finally:
                conn.execute('REVERT;')
            # A's real transaction helper against the isolated fixture, not a fake connection.
            from app.common.config import DbConfig
            from app.common import errors, tx
            config = DbConfig(driver='ODBC Driver 18 for SQL Server', server=server,
                              database=name, trusted_connection=True,
                              trust_server_certificate='yes')
            from app.common import db
            pay_values = fixtures['Payment'][1]
            statement = 'INSERT dbo.Payment VALUES ('+','.join('?' for _ in pay_values)+')'
            def fail_second_step(real_connection):
                real_connection.execute(statement, pay_values)
                real_connection.execute("THROW 52202, 'B fixture transaction rollback probe', 1;")
            with patch('app.common.db._config', return_value=config):
                long_unicode = 'x'*5000 + '中'
                echoed = db.query(None, 'SELECT CAST(? AS NVARCHAR(MAX)) AS text_value, CAST(? AS DECIMAL(10,2)) AS amount, CAST(? AS VARCHAR(100)) AS nullable_value',
                                  [db.p_nvarchar(long_unicode, 0), db.p_decimal(Decimal('24.10'), 10, 2), db.p_varchar(None, 100)])
                self.assertEqual(echoed, [{'text_value': long_unicode, 'amount': Decimal('24.10'), 'nullable_value': None}])
                with self.assertRaises(errors.AppError) as rollback_error:
                    tx.run_in_transaction(None, fail_second_step)
                self.assertEqual(rollback_error.exception.sql_number, 52202)
                self.assertEqual(conn.execute('SELECT COUNT(*) FROM dbo.Payment').fetchval(), 0)
                tx.run_in_transaction(None, lambda real_connection: real_connection.execute(statement, pay_values))
                self.assertEqual(conn.execute('SELECT COUNT(*) FROM dbo.Payment').fetchval(), 1)
        finally:
            if conn is not None:
                conn.close()
            if created:
                # Exact validated, uniquely created target only. Never use KFC_DB here.
                admin.execute('ALTER DATABASE ['+name+'] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;')
                admin.execute('DROP DATABASE ['+name+'];')
            admin.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
