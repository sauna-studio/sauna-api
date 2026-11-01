"""Fixed PostgreSQL prerequisites managed outside Atlas CE (tracking Issue64)."""
import json

EXPECTED = {'extension': 'btree_gist', 'version': '1.8', 'schema': 'extensions', 'owner': 'postgres'}

# Candidate data must not become bootstrap-superuser SQL while a development
# credential is mounted. Only these reviewed literals can initialize a NEW DB.
BOOTSTRAP_SQL = """
CREATE SCHEMA extensions AUTHORIZATION postgres;
CREATE EXTENSION btree_gist WITH SCHEMA extensions VERSION '1.8';
REVOKE ALL ON SCHEMA extensions FROM PUBLIC;
GRANT USAGE ON SCHEMA extensions TO sauna_admin, sauna_app;
REVOKE CREATE ON SCHEMA extensions FROM sauna_admin, sauna_app;
"""

VERIFY_SQL = """
SELECT count(*) FROM pg_extension AS e
JOIN pg_namespace AS n ON n.oid=e.extnamespace
JOIN pg_roles AS r ON r.oid=e.extowner
JOIN pg_available_extension_versions AS a ON a.name=e.extname AND a.version=e.extversion
WHERE e.extname='btree_gist' AND e.extversion='1.8'
  AND n.nspname='extensions' AND n.nspowner=r.oid AND r.rolname='postgres'
  AND a.trusted AND a.relocatable
  AND has_schema_privilege('sauna_admin',n.oid,'USAGE')
  AND has_schema_privilege('sauna_app',n.oid,'USAGE')
  AND NOT has_schema_privilege('sauna_admin',n.oid,'CREATE')
  AND NOT has_schema_privilege('sauna_app',n.oid,'CREATE')
  AND NOT has_schema_privilege('sauna_app','public','CREATE')
  AND NOT has_database_privilege('sauna_app',current_database(),'CREATE')
  AND NOT pg_has_role('sauna_app','postgres','MEMBER')
  AND NOT pg_has_role('sauna_app','pg_database_owner','MEMBER')
  AND NOT EXISTS (SELECT 1 FROM pg_auth_members AS membership
      WHERE membership.member IN (SELECT oid FROM pg_roles WHERE rolname IN ('sauna_app','sauna_admin')))
  AND (SELECT count(*) FROM pg_roles AS app WHERE app.rolname IN ('sauna_app','sauna_admin')
      AND NOT app.rolsuper AND NOT app.rolcreatedb AND NOT app.rolcreaterole
      AND NOT app.rolreplication AND NOT app.rolbypassrls AND app.rolcanlogin)=2
  AND EXISTS (
      SELECT 1 FROM pg_opclass AS o
      JOIN pg_am AS am ON am.oid=o.opcmethod
      JOIN pg_depend AS d ON d.classid='pg_opclass'::regclass AND d.objid=o.oid
        AND d.refclassid='pg_extension'::regclass AND d.refobjid=e.oid AND d.deptype='e'
      WHERE o.opcnamespace=n.oid AND o.opcname='gist_uuid_ops'
        AND am.amname='gist' AND o.opcowner=r.oid
  );
"""


def validate_manifest(content):
    def unique(pairs):
        if len({key for key, _ in pairs}) != len(pairs):
            raise ValueError('Duplicate prerequisite key')
        return dict(pairs)
    try:
        if not isinstance(content, bytes) or not (1 <= len(content) <= 4096):
            raise ValueError('Invalid prerequisite manifest')
        value = json.loads(content.decode('utf-8'), object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise RuntimeError('PostgreSQL prerequisite manifest is not the reviewed fixed configuration') from None
    if value != EXPECTED:
        raise RuntimeError('PostgreSQL prerequisite manifest is not the reviewed fixed configuration')
