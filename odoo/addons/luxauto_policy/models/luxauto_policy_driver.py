from odoo import fields, models


class LuxautoPolicyDriver(models.Model):
    _name = 'luxauto.policy.driver'
    _description = 'Luxury Auto Policy Driver (read-only, backed by luxauto_policy_driver_view)'
    _auto = False
    _table = 'luxauto_policy_driver_view'
    _rec_name = 'name'
    _order = 'policy_id, name'

    policy_driver_id = fields.Char(string='Policy Driver ID', readonly=True)
    policy_id = fields.Char(string='Policy ID', readonly=True)
    name = fields.Char(readonly=True)
    relationship_to_applicant = fields.Char(string='Relationship', readonly=True)
    date_of_birth = fields.Date(readonly=True)
    years_licensed = fields.Integer(readonly=True)
    license_status = fields.Char(readonly=True)
    violations_last_5yr = fields.Integer(string='Violations (5yr)', readonly=True)
    at_fault_accidents_last_5yr = fields.Integer(string='At-Fault Accidents (5yr)', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_policy_driver_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_policy_driver_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
