from odoo import fields, models


class LuxautoUnderwriter(models.Model):
    _name = 'luxauto.underwriter'
    _description = 'Luxury Auto Underwriter Roster (read-only, backed by luxauto_underwriter_view)'
    _auto = False
    _table = 'luxauto_underwriter_view'
    _rec_name = 'name'
    _order = 'name'

    underwriter_id = fields.Char(string='Underwriter ID', readonly=True)
    name = fields.Char(readonly=True)
    authority_level = fields.Char(string='Authority Level', readonly=True)
    # is_active, NOT active: an Odoo field literally named `active` triggers
    # archive magic (inactive rows hidden by default), which would hide
    # deactivated underwriters from the roster screen that exists to see and
    # reactivate them. The SQL view aliases underwriters.active -> is_active.
    is_active = fields.Boolean(string='Active', readonly=True)
    created_at = fields.Datetime(string='Added', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_underwriter_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_underwriter_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
