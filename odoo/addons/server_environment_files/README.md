# `server_environment_files`

OCA `server_environment`'s config directory for this deployment. ADR 0009 Deviation 7.

This is **not an Odoo module** — it has no `__manifest__.py` and is never installed. It is a
plain Python package that `server_environment` imports by name:

```python
from odoo.addons import server_environment_files
_dir = os.path.dirname(server_environment_files.__file__)
```

Because the import goes through the `odoo.addons` namespace, this package works from **any**
entry in `addons_path`. It lives here, in the first-party repo, rather than in the OCA
`server-env` clone where it originally sat — see "Why it moved" below.

## What it does

`production/fs_storage.conf` sets `use_as_default_for_attachments = true` on the
`azure_blob_documents` storage record, which is what makes new Odoo attachments go to Azure
Blob Storage instead of the local filestore. That field has no database column; this file is
the only thing that sets it.

`production/` must match `running_env` in `/etc/odoo/odoo.conf`. Both are `production` here.
Files must end in `.conf` — `server_env.py`'s `_listconf()` filters strictly on that suffix
and ignores `.cfg`.

## Do not put credentials here

**This directory is version-controlled and this repository is public.**

That is safe today because the only value here is a boolean. It is worth stating explicitly
because `server_environment` exists precisely to hold environment-specific values, and
credentials are the most common thing people put in it — so the obvious next edit to this
file is the wrong one.

The Azure Blob credentials this storage record uses (`account_name`, `account_key`) are
**not** here. They live in the `luxauto` database, in `fs_storage.server_env_defaults`, and
are supplied out of band. If a future value here genuinely needs to be secret, use one of:

- `server_environment`'s `SERVER_ENV_CONFIG` / `SERVER_ENV_CONFIG_SECRET` environment
  variables, set on the `odoo` systemd unit — never committed; or
- the existing Key Vault → managed identity path (ADR 0009), the way the Postgres
  credentials are handled.

## Why it moved out of the OCA clone

It used to live at `/opt/odoo-custom-addons/server-env/server_environment_files` — a
directory this project created *inside a clone of someone else's repository*. Upstream does
not track anything by that name and does not `.gitignore` it, so `git status` in that clone
reported it as untracked foreign matter indefinitely. Any routine `git clean -fdx`, or a
re-clone of `server-env` to pick up upstream changes, would delete it — and two of the three
resulting failure modes are silent (see ADR 0009 Deviation 7).

Moving it here makes it survive by the same mechanism as every other file in this project.

## If you change this file

A change here only takes effect on an Odoo **restart** — `server_environment` reads these
files at import time, not per request. `scripts/deploy-vm.sh` restarts Odoo, so a normal
deploy picks it up.

`scripts/lib/smoke_test.py` asserts that attachment storage actually resolves to
`azure_blob_documents` and fails the deploy if it does not, so a mistake here is loud rather
than silent. That check is the reason this directory is no longer a single point of quiet
failure — keep it working.
