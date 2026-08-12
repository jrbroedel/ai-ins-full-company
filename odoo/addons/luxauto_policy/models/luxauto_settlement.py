from odoo import fields, models


class LuxautoSettlement(models.Model):
    _name = 'luxauto.settlement'
    _description = 'Luxury Auto Settlement Report (read-only, backed by luxauto_settlement_view)'
    _auto = False
    _table = 'luxauto_settlement_view'
    _rec_name = 'policy_number'
    _order = 'bind_date desc, policy_number'

    policy_id = fields.Char(string='Policy ID', readonly=True)
    policy_number = fields.Char(readonly=True)
    policy_status = fields.Char(string='Policy Status', readonly=True)
    # bind_date, not effective_range - a settlement report reflects when premium
    # was written, not when coverage is active (ADR 0013 section 1). This is the
    # field the search view's period filter runs on.
    bind_date = fields.Datetime(string='Bind Date', readonly=True)
    quote_id = fields.Char(string='Quote ID', readonly=True)
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
        self.env.cr.execute("SELECT to_regclass('public.luxauto_settlement_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_settlement_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
