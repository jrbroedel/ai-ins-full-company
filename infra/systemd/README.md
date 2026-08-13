# systemd units (ADR 0019)

`luxauto-expire-policies.{service,timer}` run `scripts/expire-policies.sh` on
`luxauto-odoo`, which calls `expire_policies()` to move policies whose term has
ended to `nonrenewed` or `expired` (ADR 0019 section 3).

Why here and not `pg_cron`: `pg_cron` is preloaded on `luxauto-pg` but is not in
that server's `azure.extensions` allow-list, so `CREATE EXTENSION pg_cron` is
refused. Allow-listing it is an Azure control-plane parameter change plus a
restart. The timer keeps the schedule versioned in this repo either way.

Install (from the deployed clone on the VM):

```
sudo cp /opt/odoo-custom-addons/luxauto/infra/systemd/luxauto-expire-policies.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now luxauto-expire-policies.timer
```

Check: `systemctl list-timers luxauto-expire-policies.timer` and
`journalctl -u luxauto-expire-policies.service`.

The unit files are not installed by `scripts/deploy-vm.sh` - that script
deploys application code, and installing system units is a privileged,
one-time operation. A deploy picks up changes to the *script*; changes to the
unit files need the copy above re-run.
