# systemd units

Two timer/service pairs run on `luxauto-odoo`. Both follow the same shape: a
oneshot service running as `odoo`, a timer with `Persistent=true`, and the
schedule kept versioned here rather than only on the host.

## `luxauto-expire-policies.{service,timer}` (ADR 0019)

Runs `scripts/expire-policies.sh`, which calls `expire_policies()` to move
policies whose term has ended to `nonrenewed` or `expired` (ADR 0019 section 3).

**Hourly**, because the thing it fixes is time-dependent: a policy whose term
ended shows the wrong status from that instant until the job runs, so an hour
is a cheap bound on visibly wrong data.

Why here and not `pg_cron`: `pg_cron` is preloaded on `luxauto-pg` but is not in
that server's `azure.extensions` allow-list, so `CREATE EXTENSION pg_cron` is
refused. Allow-listing it is an Azure control-plane parameter change plus a
restart. The timer keeps the schedule versioned in this repo either way.

## `luxauto-verify-attachment-storage.{service,timer}` (ADR 0009 Deviation 7, second addendum)

Runs `scripts/verify-attachment-storage.sh`, which confirms both that Odoo still
intends to store attachments in Azure Blob *and* that Blob actually accepts a
write/read/delete round-trip.

**Daily**, deliberately not hourly — see the timer file's own comment for the
reasoning. In short: nothing here changes on its own, deploys are already
covered by `smoke_test.py`, and with no alerting configured anywhere on this
project a more frequent check would not shorten the time to *notice* a failure,
only the time to write it into a log.

Exit codes are distinct so `systemctl status` tells you what broke:
`1` intent, `2` reachability, `3` both, `4` could not run.

**A failed run notifies nobody.** It is visible in `systemctl status` and the
journal on this host and nowhere else. That is a known, named gap — see the ADR
addendum.

## Install (from the deployed clone on the VM)

```
sudo cp /opt/odoo-custom-addons/luxauto/infra/systemd/luxauto-expire-policies.* /etc/systemd/system/
sudo cp /opt/odoo-custom-addons/luxauto/infra/systemd/luxauto-verify-attachment-storage.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now luxauto-expire-policies.timer
sudo systemctl enable --now luxauto-verify-attachment-storage.timer
```

Check: `systemctl list-timers 'luxauto-*'` and
`journalctl -u luxauto-expire-policies.service`,
`journalctl -u luxauto-verify-attachment-storage.service`.

To run either check immediately rather than waiting for its schedule:
`sudo systemctl start luxauto-verify-attachment-storage.service`.

The unit files are not installed by `scripts/deploy-vm.sh` - that script
deploys application code, and installing system units is a privileged,
one-time operation. A deploy picks up changes to the *scripts*; changes to the
unit files need the copy above re-run.
