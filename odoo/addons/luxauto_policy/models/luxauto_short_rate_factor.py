from odoo import fields, models


class LuxautoShortRateFactor(models.Model):
    _name = 'luxauto.short.rate.factor'
    _description = 'Luxury Auto Short-Rate Factor (read-only reference, backed by luxauto_short_rate_factor_view)'
    _auto = False
    _table = 'luxauto_short_rate_factor_view'
    _rec_name = 'state'
    _order = 'state, created_at desc'

    short_rate_factor_id = fields.Char(string='Short-Rate Factor ID', readonly=True)
    state = fields.Char(readonly=True)
    # NULL means the row applies to any program in this state (short_rate_factor()
    # prefers a program-specific row when one exists). Mapped as Char like every
    # other id here - the model is _auto=False over a view, so there is no
    # relational column to key a many2one against.
    program_id = fields.Char(string='Program ID', readonly=True)
    elapsed_fraction_from = fields.Float(string='Elapsed Fraction From', digits=(5, 4), readonly=True)
    elapsed_fraction_to = fields.Float(string='Elapsed Fraction To', digits=(5, 4), readonly=True)
    factor = fields.Float(digits=(6, 4), readonly=True)
    basis = fields.Char(string='Basis', readonly=True)
    # NULL means the factor applies to both cancellation types; a state that
    # permits short-rate only on insured-initiated cancellations says so here.
    applies_to = fields.Char(string='Applies To', readonly=True)
    # effective_range is a Postgres tstzrange on the underlying table - Odoo has no
    # native range field type (same as luxauto.policy), so the view derives these
    # two immutable bounds from it and leaves the range itself unmapped.
    effective_from = fields.Datetime(string='Effective From', readonly=True)
    effective_to = fields.Datetime(string='Effective To', readonly=True)
    serff_filing_tracking_number = fields.Char(string='SERFF Filing Tracking Number', readonly=True)
    rate_manual_reference = fields.Char(string='Rate Manual Reference', readonly=True)
    created_at = fields.Datetime(string='Recorded At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_short_rate_factor_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_short_rate_factor_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
