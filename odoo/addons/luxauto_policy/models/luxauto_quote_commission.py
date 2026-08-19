from odoo import fields, models


class LuxautoQuoteCommission(models.Model):
    _name = 'luxauto.quote.commission'
    _description = 'Luxury Auto Quote Commission (read-only, backed by luxauto_quote_commission_view)'
    _auto = False
    _table = 'luxauto_quote_commission_view'
    _rec_name = 'quote_id'
    _order = 'quoted_at desc'

    quote_id = fields.Char(string='Quote ID', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    program_id = fields.Char(string='Program ID', readonly=True)
    premium_amount = fields.Float(string='Premium Amount', digits=(12, 2), readonly=True)
    broker_channel = fields.Char(string='Broker Channel', readonly=True)
    broker_commission_rate = fields.Float(string='Broker Commission %', digits=(5, 2), readonly=True)
    # ADR 0007 addendum: always 30 - broker (a GENERATED column on quotes), so
    # broker + MGA = 30 is a schema fact, not a display convention.
    mga_commission_rate = fields.Float(string='MGA Commission %', digits=(5, 2), readonly=True)
    quote_status = fields.Char(string='Quote Status', readonly=True)
    quoted_at = fields.Datetime(string='Quoted At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_quote_commission_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_quote_commission_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
