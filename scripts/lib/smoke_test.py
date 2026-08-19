"""
Post-deploy smoke test (ADR 0015 section 3). Run via `odoo shell` (needs the
local `env` it provides to create/delete a disposable user), but the actual
verification goes over real XML-RPC as that user - the same real-auth,
real-ACL path a browser uses, not the shell's superuser bypass. Confirms all
13 luxauto.* models in MODELS below are actually queryable post-deploy, not
just that the Odoo service is active - and the read-only, _auto=False models
backed by SQL views (every ADR 0029 model, plus the older waterfall/settlement)
answer search_read over that path exactly as the regular-table models do.

Also asserts that attachment storage still resolves to Azure Blob - see
check_attachment_storage() below for why that needs a deploy-time check at all.

Invoke as:
  sudo -u odoo /usr/bin/odoo shell --config /etc/odoo/odoo.conf -d luxauto \
    --no-http < scripts/lib/smoke_test.py
"""
import secrets
import xmlrpc.client

URL = 'https://mga.ironcliffvertex.com'
DB = 'luxauto'
MODELS = [
    'luxauto.insured', 'luxauto.policy', 'luxauto.policy.vehicle', 'luxauto.policy.driver',
    'luxauto.policy.cancellation', 'luxauto.premium.waterfall', 'luxauto.settlement',
    # ADR 0029 read-side visibility views. Same _auto=False view-backed pattern as
    # waterfall/settlement above, so the same search_read probe covers them.
    'luxauto.policy.reinstatement', 'luxauto.short.rate.factor', 'luxauto.decision.log',
    'luxauto.application.referral', 'luxauto.quote.commission', 'luxauto.quote.rating',
]
# The fs.storage record attachments are supposed to land in (ADR 0009).
EXPECTED_ATTACHMENT_STORAGE = 'azure_blob_documents'
LOGIN = f'deploy-smoke-test-{secrets.token_hex(4)}@luxauto.local'
PASSWORD = secrets.token_urlsafe(16)

def check_attachment_storage():
    """Assert new attachments would go to Azure Blob, not the local filestore.

    This exists because the failure it catches is silent. Blob storage is
    switched on by `use_as_default_for_attachments`, which is a
    config-file-only field of the OCA server_environment mechanism - it has no
    column in Postgres (checked: information_schema has no such column on
    fs_storage), so there is no database state to fall back on. The only thing
    that sets it is odoo/addons/server_environment_files/production/fs_storage.conf.

    Two of the three ways that config can go missing produce no error at all:

      - the whole server_environment_files package gone -> server_env.py
        catches ImportError and logs at INFO, then sets _dir = None;
      - fs_storage.conf gone or unreadable -> _listconf() just returns a
        shorter list and the field falls back to its Python default, False.

    (The third - the production/ subdirectory gone while the package remains -
    raises at import and Odoo refuses to start, which needs no help from here.)

    In both silent cases Odoo keeps running, every model still answers, and
    ir.attachment._storage() quietly returns stock Odoo's answer instead. With
    no ir_attachment.location parameter set on this database, that answer is
    'file' - the local filestore on the VM's own disk, which is exactly the
    state a VM rebuild would destroy. Nothing else in this deploy would notice.

    _storage() is the real resolver fs_attachment overrides and the same call
    _file_write() makes when storing a new attachment, so this asserts the
    actual code path rather than re-reading the config and hoping.
    """
    storage = env['ir.attachment'].sudo()._storage()
    if storage != EXPECTED_ATTACHMENT_STORAGE:
        return (
            f'FAIL: attachment storage resolved to {storage!r}, expected '
            f'{EXPECTED_ATTACHMENT_STORAGE!r} - new attachments are NOT going to '
            f'Azure Blob. Check that '
            f'odoo/addons/server_environment_files/production/fs_storage.conf '
            f'exists in the deployed clone and that running_env=production is set '
            f'in odoo.conf (ADR 0009 Deviation 7).'
        )
    return 'PASS'


group_ids = [env.ref(x).id for x in ['base.group_user', 'luxauto_policy.group_settlement_viewer']]
user = env['res.users'].sudo().create({
    'name': 'Deploy Smoke Test',
    'login': LOGIN,
    'password': PASSWORD,
    'group_ids': [(6, 0, group_ids)],
})
env.cr.commit()

results = {}
try:
    common = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/common')
    uid = common.authenticate(DB, LOGIN, PASSWORD, {})
    if not uid:
        raise RuntimeError('authentication failed')
    models_proxy = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/object')
    for model in MODELS:
        try:
            models_proxy.execute_kw(DB, uid, PASSWORD, model, 'search_read', [[], ['id']])
            results[model] = 'PASS'
        except Exception as exc:
            results[model] = f'FAIL: {exc}'
except Exception as exc:
    for model in MODELS:
        results.setdefault(model, f'FAIL: {exc}')
finally:
    env['res.users'].sudo().browse(user.id).unlink()
    env.cr.commit()

# Runs after the model checks and outside their try/finally: the disposable
# user must be cleaned up regardless, and this check neither needs that user nor
# should be skipped because a model failed - a deploy can plausibly break
# attachment storage and nothing else.
try:
    checks = {'attachment_storage': check_attachment_storage()}
except Exception as exc:
    checks = {'attachment_storage': f'FAIL: {exc}'}

overall = 'PASS' if all(
    v == 'PASS' for v in list(results.values()) + list(checks.values())
) else 'FAIL'
for model, result in results.items():
    print(f"SMOKE_TEST_MODEL={model} RESULT={result}")
for check, result in checks.items():
    print(f"SMOKE_TEST_CHECK={check} RESULT={result}")
print(f"SMOKE_TEST_RESULT={overall}")
