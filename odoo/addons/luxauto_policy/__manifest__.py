{
    'name': 'Luxury Auto Policy',
    'version': '19.0.1.0.0',
    'summary': 'Read-only Insured/Policy/Vehicle/Driver/Cancellation/Waterfall/Settlement/Reinstatement/Short-Rate/Referral/Commission/Rating views over the pipeline database (ADR 0010/0013/0016/0018/0029)',
    'description': """
Luxury Auto Policy
===================

Read-only Odoo models backed directly by the luxauto_insured_view,
luxauto_policy_view, luxauto_policy_vehicle_view, luxauto_policy_driver_view,
luxauto_policy_cancellation_view, luxauto_premium_waterfall_view, and
luxauto_settlement_view SQL views defined in
schemas/db/postgresql_schema.sql (ADR 0006's _auto=False pattern, ADR
0010's scope, ADR 0013's settlement report, ADR 0016's structural policy
ownership, ADR 0018's addendum for the cancellation read side). The
pipeline's UUID-keyed tables remain the system of record; these models never
write to them.

luxauto.policy.cancellation shows every cancellation row, superseded ones
included, exactly as the vehicle and driver views show every snapshot row. A
corrected cancellation leaves the original emptied and inserts a replacement
(ADR 0018 section 6); the Superseded column is how the two are told apart.
The cancel wizard remains the only write path.

A bound policy owns its own snapshot of vehicles and drivers, taken at bind
time (ADR 0016) - luxauto.policy.vehicle/luxauto.policy.driver show that
snapshot, not the application's live (and possibly since-changed) rows.
Correcting a mistaken snapshot row goes through correct_policy_vehicle()/
correct_policy_driver() (schemas/db/postgresql_schema.sql) - no wizard for
that here yet, same as bind/cancel got a wizard in a later step after the
functions existed first.

luxauto.settlement (the capacity-provider settlement report) is gated behind
its own security group, luxauto_policy.group_settlement_viewer, rather than
base.group_user - it exposes commission rates and participant splits, more
sensitive than the other models here. No user is added to that group by
default.

ADR 0029 adds six read-only models for the domains whose write/compute side
shipped in ADRs 0024-0028 with the Odoo read side deferred and batched here:
luxauto.policy.reinstatement (the backdated-reinstatement audit record),
luxauto.short.rate.factor (the configured short-rate reference table - the
factor actually applied to a cancellation is already on
luxauto.policy.cancellation), luxauto.application.referral (per-application
summary: most-severe action derived from the decision log without re-running
the orchestrator) and luxauto.decision.log (the per-rule detail behind it),
luxauto.quote.commission (broker channel + broker/MGA rates + premium), and
luxauto.quote.rating (the v1 rating_basis breakdown unpacked into typed
columns). All are backed by luxauto_*_view SQL views and open to
base.group_user; luxauto.quote.commission follows luxauto.premium.waterfall
(open) rather than the gated settlement report, a deliberate ADR 0029 choice.
luxauto.quote.rating renders NULLs until quote creation is wired to write a
v1-shaped rating_basis - compute_indicative_premium() exists but is not yet
called on quote insert, a scoped-out follow-up flagged in ADR 0029, not part
of this read-only pass.

Writes (binding a quote into a policy, cancelling a policy) go through
explicit server actions, not the read-only models above - see ADR 0010
section 4. Each calls a SECURITY DEFINER Postgres function
(bind_policy/cancel_policy in schemas/db/postgresql_schema.sql) via a small
wizard, rather than writing to the pipeline tables directly.
""",
    'category': 'Industries',
    'author': 'Luxury Auto MGA',
    'license': 'AGPL-3',
    'depends': ['base'],
    'data': [
        'security/luxauto_security.xml',
        'security/ir.model.access.csv',
        'views/luxauto_insured_views.xml',
        'views/luxauto_policy_views.xml',
        'views/luxauto_policy_vehicle_views.xml',
        'views/luxauto_policy_driver_views.xml',
        'views/luxauto_policy_cancellation_views.xml',
        'views/luxauto_premium_waterfall_views.xml',
        'views/luxauto_settlement_views.xml',
        'views/luxauto_policy_reinstatement_views.xml',
        'views/luxauto_short_rate_factor_views.xml',
        'views/luxauto_decision_log_views.xml',
        'views/luxauto_application_referral_views.xml',
        'views/luxauto_quote_commission_views.xml',
        'views/luxauto_quote_rating_views.xml',
        'views/luxauto_bind_wizard_views.xml',
        'views/luxauto_menus.xml',
    ],
    'installable': True,
    'application': True,
}
