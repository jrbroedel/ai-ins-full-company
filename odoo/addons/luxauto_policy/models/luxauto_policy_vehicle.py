from odoo import fields, models


class LuxautoPolicyVehicle(models.Model):
    _name = 'luxauto.policy.vehicle'
    _description = 'Luxury Auto Policy Vehicle (read-only, backed by luxauto_policy_vehicle_view)'
    _auto = False
    _table = 'luxauto_policy_vehicle_view'
    _rec_name = 'vin'
    _order = 'policy_id, vin'

    policy_vehicle_id = fields.Char(string='Policy Vehicle ID', readonly=True)
    policy_id = fields.Char(string='Policy ID', readonly=True)
    year = fields.Integer(readonly=True)
    make = fields.Char(readonly=True)
    model = fields.Char(readonly=True)
    trim = fields.Char(readonly=True)
    vin = fields.Char(string='VIN', readonly=True)
    vehicle_category = fields.Char(readonly=True)
    garaging_state = fields.Char(string='Garaging State', readonly=True)
    agreed_value_requested = fields.Boolean(readonly=True)
    current_appraised_value = fields.Float(string='Appraised Value', digits=(12, 2), readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_policy_vehicle_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_policy_vehicle_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
