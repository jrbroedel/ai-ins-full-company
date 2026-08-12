{
    'name': 'Luxury Auto Policy',
    'version': '19.0.1.0.0',
    'summary': 'Read-only Insured/Policy/Premium Waterfall views over the pipeline database (ADR 0010)',
    'description': """
Luxury Auto Policy
===================

Read-only Odoo models backed directly by the luxauto_insured_view,
luxauto_policy_view, and luxauto_premium_waterfall_view SQL views defined in
schemas/db/postgresql_schema.sql (ADR 0006's _auto=False pattern, ADR 0010's
scope). The pipeline's UUID-keyed tables remain the system of record; these
models never write to them.

Writes (binding a quote into a policy, cancelling a policy) go through
explicit server actions, not this module - see ADR 0010 section 4. Not built
here yet.
""",
    'category': 'Industries',
    'author': 'Luxury Auto MGA',
    'license': 'AGPL-3',
    'depends': ['base'],
    'data': [
        'security/ir.model.access.csv',
        'views/luxauto_insured_views.xml',
        'views/luxauto_policy_views.xml',
        'views/luxauto_premium_waterfall_views.xml',
        'views/luxauto_menus.xml',
    ],
    'installable': True,
    'application': True,
}
