"""
Standing attachment-storage health check (ADR 0009 Deviation 7, second addendum).

Run via `odoo shell`, the same execution pattern as scripts/lib/smoke_test.py.
Invoked by scripts/verify-attachment-storage.sh, which the
luxauto-verify-attachment-storage systemd timer runs daily.

WHY THIS EXISTS SEPARATELY FROM smoke_test.py
---------------------------------------------
smoke_test.py's attachment check closed one gap and explicitly left two open:

  1. It only runs on deploy. A regression between deploys - a rotated storage
     key, a deleted container, a hand-edited config, a restored VM - goes
     unnoticed until somebody happens to push.
  2. It only proves INTENT. `ir.attachment._storage()` returning
     'azure_blob_documents' says Odoo means to write to Blob; it says nothing
     about whether Blob would accept the write. Every credential and network
     failure mode is invisible to it.

This script closes both. It runs on a timer, and it proves reachability the way
ADR 0009 originally did when the Blob wiring was first accepted: not by
re-reading configuration, but by putting bytes in Blob and getting them back.

WHAT IT CHECKS
--------------
The two checks are deliberately INDEPENDENT and both always run - a report
saying "intent is wrong" should not hide "and Blob is also unreachable", since
those have different causes and different fixes.

  intent        `ir.attachment._storage()` resolves to the expected storage
                code, i.e. a NEW attachment created right now would go to Blob
                rather than the local filestore. This is the same assertion
                smoke_test.py makes.

  reachability  A real round-trip, mirroring ADR 0009's original three-way
                verification:
                  (a) create an ir.attachment through the normal ORM API and
                      confirm fs_filename is populated and db_datas is empty -
                      proof the bytes left the database;
                  (b) read the content back through the ORM and compare;
                  (c) read the same object again with fsspec directly, at the
                      path parsed out of store_fname, bypassing Odoo's
                      abstraction entirely - proof the bytes are really in
                      Azure Blob and not merely somewhere Odoo believes;
                  (d) delete the object through fsspec and confirm it is gone -
                      a third Blob operation, so the check covers write, read
                      and delete rather than only the first two.

                The attachment is forced onto the expected storage with
                `storage_location` in the context, so reachability is tested
                against Blob even when the intent check has already failed and
                a default-routed attachment would have gone to local disk.

WHY (d) DELETES THROUGH fsspec RATHER THAN THROUGH unlink()
-----------------------------------------------------------
Because `ir.attachment.unlink()` does not delete the object, and finding that
out is what the first run of this check did. Odoo's unlink calls
`_file_delete`, which fs_attachment overrides to call `_storage_file_delete`,
which calls `_fs_mark_for_gc` - it MARKS the object for a later garbage
collection pass and returns. Nothing removes it from the container at that
moment.

So a probe that creates an attachment and relies on unlink to tidy up leaves
its object sitting in the production container until the GC happens to run,
and an assertion that the object is gone immediately after unlink fails
against a perfectly healthy system - which is exactly what happened here
before this was understood. Deleting through fsspec is both the honest
cleanup and a stronger check: it exercises a real Blob delete instead of a
database write that promises one eventually.

CLEANUP
-------
Three layers, because leaving debris in a production container is the one
side effect this check must not have:

  - (d) removes the object explicitly through fsspec on the success path;
  - a `finally` removes it if any assertion returned early after the write,
    and reports on VERIFY_CLEANUP if that removal itself fails;
  - the transaction is rolled back rather than committed, so the ir.attachment
    row never lands even if the process is killed.

The object name carries a `luxauto-storage-healthcheck-` prefix and a
timestamp so that anything a `kill -9` does manage to strand between the write
and the delete is immediately identifiable as this check's debris.

Env overrides (both exist for the failure-reproduction tests):
  LUXAUTO_EXPECTED_STORAGE   storage code to expect and test (default
                             azure_blob_documents)
"""
import os
import secrets
import traceback
from datetime import datetime, timezone

EXPECTED_STORAGE = os.environ.get('LUXAUTO_EXPECTED_STORAGE', 'azure_blob_documents')

_token = secrets.token_hex(8)
_stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
# Clearly marked so that an object found in the container by a human, or left
# behind by a kill -9 between the write and the unlink, is immediately
# identifiable as this check's debris and not real data.
NAME = f'luxauto-storage-healthcheck-{_stamp}-{_token}.bin'
PAYLOAD = (
    f'luxauto attachment-storage health check\n'
    f'written {_stamp} by scripts/lib/verify_attachment_storage.py\n'
    f'token {_token}\n'
    f'SAFE TO DELETE - this is a synthetic probe, not application data.\n'
).encode()

results = {}


def check_intent():
    """Would a new attachment created right now go to Blob?"""
    storage = env['ir.attachment'].sudo()._storage()
    if storage != EXPECTED_STORAGE:
        return (
            f'FAIL: ir.attachment._storage() resolved to {storage!r}, expected '
            f'{EXPECTED_STORAGE!r}. New attachments are NOT going to Azure Blob - '
            f"with no ir_attachment.location parameter set, {storage!r} means the "
            f"local filestore on this VM's own disk. Check that "
            f'odoo/addons/server_environment_files/production/fs_storage.conf is '
            f'present in the deployed clone and that running_env=production is set '
            f'in /etc/odoo/odoo.conf (ADR 0009 Deviation 7).'
        )
    return 'PASS'


def check_reachability():
    """Write, read back twice, and delete a real object in Blob."""
    Attachment = env['ir.attachment'].sudo()
    storage = env['fs.storage'].sudo().search([('code', '=', EXPECTED_STORAGE)])
    if not storage:
        return (
            f'FAIL: no fs.storage record with code {EXPECTED_STORAGE!r} exists. '
            f'The storage record lives in the luxauto database (it survives a VM '
            f'rebuild); if it is missing, Blob storage was never configured or the '
            f'record was deleted.'
        )

    attachment = None
    blob_fs = None
    blob_path = None
    try:
        # (a) Write through the ORM, forced onto the expected storage so this
        #     check is independent of whether the default currently points there.
        attachment = Attachment.with_context(
            storage_location=EXPECTED_STORAGE
        ).create({
            'name': NAME,
            'raw': PAYLOAD,
            'mimetype': 'application/octet-stream',
        })

        if not attachment.fs_filename:
            return (
                f'FAIL: attachment was created but fs_filename is empty, so the '
                f'bytes did not leave the database. store_fname='
                f'{attachment.store_fname!r}. Blob was not written to at all.'
            )
        if attachment.db_datas:
            return (
                'FAIL: attachment was stored in the database (db_datas is set) '
                'despite being forced onto ' + repr(EXPECTED_STORAGE) + '.'
            )

        # (b) Read back through Odoo's own abstraction.
        if attachment.raw != PAYLOAD:
            return (
                f'FAIL: content read back through the ORM does not match what was '
                f'written ({len(attachment.raw or b"")} bytes back, '
                f'{len(PAYLOAD)} written).'
            )

        # (c) Read the same object again with fsspec directly, bypassing Odoo.
        #     This is what distinguishes "Odoo thinks it wrote to Blob" from
        #     "the bytes are in Blob" - the distinction ADR 0009 made a point of.
        blob_fs, _code, blob_path = Attachment._fs_parse_store_fname(
            attachment.store_fname
        )
        direct = blob_fs.cat_file(blob_path)
        if direct != PAYLOAD:
            return (
                f'FAIL: content read directly from Blob via fsspec does not match '
                f'what was written ({len(direct or b"")} bytes at {blob_path!r}). '
                f'Odoo reported success but the object in Blob is wrong.'
            )

        # (d) Delete through fsspec - see the module docstring for why not
        #     through unlink(). invalidate_cache() first, because fsspec caches
        #     directory listings and a stale one would make this assertion
        #     answer from memory instead of from Azure.
        blob_fs.rm(blob_path)
        blob_fs.invalidate_cache()
        if blob_fs.exists(blob_path):
            return (
                f'FAIL: object still present in Blob at {blob_path!r} after an '
                f'explicit fsspec delete. Write and read work, but delete does '
                f'not - check the storage account key\'s permissions.'
            )
        blob_path = None

        # The row itself. Rolled back below in any case; unlinking here keeps
        # the transaction honest rather than relying solely on the rollback.
        attachment.unlink()
        attachment = None

        return 'PASS'

    except Exception as exc:
        return f'FAIL: {type(exc).__name__}: {exc}'
    finally:
        # Belt and braces: if any assertion above returned early after the write,
        # the object is still in the container and unlink() alone would not
        # remove it (it only marks for GC). Remove it explicitly here. Failures
        # during cleanup are reported on their own line rather than replacing
        # the original result, which is the thing worth reading.
        if blob_path is not None and blob_fs is not None:
            try:
                blob_fs.rm(blob_path)
            except Exception as exc:
                print(
                    f'VERIFY_CLEANUP=FAILED object={blob_path} error={exc} '
                    f'- a probe object may be left in the container; it is safe '
                    f'to delete and is named {NAME}'
                )
        if attachment is not None:
            try:
                attachment.unlink()
            except Exception as exc:
                print(f'VERIFY_CLEANUP=FAILED attachment={NAME} error={exc}')


for name, fn in (('intent', check_intent), ('reachability', check_reachability)):
    try:
        results[name] = fn()
    except Exception:
        results[name] = f'FAIL: {traceback.format_exc(limit=3)}'

# Never commit. The attachment was created and deleted inside this transaction,
# so rolling back guarantees the database is untouched even if the unlink above
# somehow did not run. The Blob object is not transactional and is handled by
# the explicit deletes.
env.cr.rollback()

overall = 'PASS' if all(v == 'PASS' for v in results.values()) else 'FAIL'
print(f'VERIFY_STORAGE={EXPECTED_STORAGE}')
for name, result in results.items():
    print(f'VERIFY_CHECK={name} RESULT={result}')
print(f'VERIFY_RESULT={overall}')
