from odoo import fields, models


class LuxautoPremiumWaterfall(models.Model):
    _name = 'luxauto.premium.waterfall'
    _description = 'Luxury Auto Premium Waterfall (read-only, backed by luxauto_premium_waterfall_view)'
    _auto = False
    _table = 'luxauto_premium_waterfall_view'
    _rec_name = 'participant_name'
    _order = 'quote_id, participant_name'

    quote_id = fields.Char(string='Quote ID', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    program_id = fields.Char(string='Program ID', readonly=True)
    premium_amount = fields.Float(string='Gross Premium', digits=(12, 2), readonly=True)
    quote_status = fields.Char(string='Quote Status', readonly=True)
    participant_id = fields.Char(string='Participant ID', readonly=True)
    participant_name = fields.Char(readonly=True)
    participant_type = fields.Char(readonly=True)
    share_percentage = fields.Float(string='Share %', digits=(5, 2), readonly=True)
    commission_rate = fields.Float(string='Commission Rate %', digits=(5, 2), readonly=True)
    gross_share = fields.Float(string='Gross Share', digits=(14, 2), readonly=True)
    commission_amount = fields.Float(string='Commission Amount', digits=(14, 2), readonly=True)
    net_due = fields.Float(string='Net Due', digits=(14, 2), readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        # The waterfall numbers themselves come from calculate_premium_waterfall()
        # (schemas/db/postgresql_schema.sql) via the view - not recomputed here,
        # per ADR 0010's "where the waterfall math lives" decision.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_premium_waterfall_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_premium_waterfall_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
