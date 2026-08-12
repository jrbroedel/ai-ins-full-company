from odoo import fields, models


class LuxautoInsured(models.Model):
    _name = 'luxauto.insured'
    _description = 'Luxury Auto Insured (read-only, backed by luxauto_insured_view)'
    _auto = False
    _table = 'luxauto_insured_view'
    _rec_name = 'last_name'
    _order = 'last_name, first_name'

    applicant_id = fields.Char(string='Applicant ID', readonly=True)
    first_name = fields.Char(readonly=True)
    last_name = fields.Char(readonly=True)
    date_of_birth = fields.Date(readonly=True)
    email = fields.Char(readonly=True)
    phone = fields.Char(readonly=True)
    mailing_city = fields.Char(string='City', readonly=True)
    mailing_state = fields.Char(string='State', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    application_status = fields.Char(string='Application Status', readonly=True)
    garaging_state = fields.Char(string='Garaging State', readonly=True)
    submitted_at = fields.Datetime(readonly=True)

    def init(self):
        # luxauto_insured_view is created and owned by schemas/db/postgresql_schema.sql
        # (ADR 0006/0010) - that file is the single source of truth for its definition.
        # This model deliberately does not (re)create the view here, to avoid a second
        # copy of that SQL drifting out of sync with the schema file. Fail loudly if
        # it's missing rather than let Odoo surface a confusing "relation does not
        # exist" error later.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_insured_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_insured_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
