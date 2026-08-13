"""
Post-deploy smoke test (ADR 0015 section 3). Run via `odoo shell` (needs the
local `env` it provides to create/delete a disposable user), but the actual
verification goes over real XML-RPC as that user - the same real-auth,
real-ACL path a browser uses, not the shell's superuser bypass. Confirms all
four luxauto.* models are actually queryable post-deploy, not just that the
Odoo service is active.

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
    'luxauto.premium.waterfall', 'luxauto.settlement',
]
LOGIN = f'deploy-smoke-test-{secrets.token_hex(4)}@luxauto.local'
PASSWORD = secrets.token_urlsafe(16)

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

overall = 'PASS' if all(v == 'PASS' for v in results.values()) else 'FAIL'
for model, result in results.items():
    print(f"SMOKE_TEST_MODEL={model} RESULT={result}")
print(f"SMOKE_TEST_RESULT={overall}")
