from odoo import fields, models


class LuxautoQuoteRating(models.Model):
    _name = 'luxauto.quote.rating'
    _description = 'Luxury Auto Quote Rating (read-only, backed by luxauto_quote_rating_view)'
    _auto = False
    _table = 'luxauto_quote_rating_view'
    _rec_name = 'quote_id'
    _order = 'quoted_at desc'

    quote_id = fields.Char(string='Quote ID', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    premium_amount = fields.Float(string='Quote Premium', digits=(12, 2), readonly=True)
    # The v1 (indicative_premium_v1) rating_basis breakdown, unpacked from the
    # JSONB on quotes into typed columns so the components that produced the
    # number are legible, not opaque. All NULL until quote creation is wired to
    # write a v1-shaped basis (ADR 0028 built compute_indicative_premium() but not
    # its call site - a scoped-out follow-up, see ADR 0029); a non-v1 basis yields
    # NULLs, not an error.
    rating_model = fields.Char(string='Rating Model', readonly=True)
    agreed_value = fields.Float(string='Agreed Value', digits=(12, 2), readonly=True)
    rating_vehicle_class = fields.Integer(string='Rating Vehicle Class', readonly=True)
    rating_class_label = fields.Char(string='Rating Class', readonly=True)
    value_band_lower = fields.Float(string='Value Band Lower', digits=(12, 2), readonly=True)
    value_band_upper = fields.Float(string='Value Band Upper', digits=(12, 2), readonly=True)
    base_rate_per_100 = fields.Float(string='Base Rate per $100', digits=(8, 4), readonly=True)
    base_loss_cost = fields.Float(string='Base Loss Cost', digits=(12, 2), readonly=True)
    territory_state = fields.Char(string='Territory State', readonly=True)
    territory_factor = fields.Float(string='Territory Factor', digits=(8, 4), readonly=True)
    gross_up_divisor = fields.Float(string='Gross-Up Divisor', digits=(8, 4), readonly=True)
    indicative_premium = fields.Float(string='Indicative Premium', digits=(12, 2), readonly=True)
    quote_status = fields.Char(string='Quote Status', readonly=True)
    quoted_at = fields.Datetime(string='Quoted At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_quote_rating_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_quote_rating_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
