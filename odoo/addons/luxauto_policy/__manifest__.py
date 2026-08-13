{
    'name': 'Luxury Auto Policy',
    'version': '19.0.1.0.0',
    'summary': 'Read-only Insured/Policy/Vehicle/Driver/Waterfall/Settlement views over the pipeline database (ADR 0010/0013/0016)',
    'description': """
Luxury Auto Policy
===================

Read-only Odoo models backed directly by the luxauto_insured_view,
luxauto_policy_view, luxauto_policy_vehicle_view, luxauto_policy_driver_view,
luxauto_premium_waterfall_view, and luxauto_settlement_view SQL views defined
in schemas/db/postgresql_schema.sql (ADR 0006's _auto=False pattern, ADR
0010's scope, ADR 0013's settlement report, ADR 0016's structural policy
ownership). The pipeline's UUID-keyed tables remain the system of record;
these models never write to them.

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
        'views/luxauto_premium_waterfall_views.xml',
        'views/luxauto_settlement_views.xml',
        'views/luxauto_bind_wizard_views.xml',
        'views/luxauto_menus.xml',
    ],
    'installable': True,
    'application': True,
}
