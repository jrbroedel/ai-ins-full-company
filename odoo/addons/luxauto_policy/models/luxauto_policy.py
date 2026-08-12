from odoo import fields, models


class LuxautoPolicy(models.Model):
    _name = 'luxauto.policy'
    _description = 'Luxury Auto Policy (read-only, backed by luxauto_policy_view)'
    _auto = False
    _table = 'luxauto_policy_view'
    _rec_name = 'policy_number'
    _order = 'policy_number'

    policy_id = fields.Char(string='Policy ID', readonly=True)
    policy_number = fields.Char(readonly=True)
    # effective_range is a Postgres tstzrange on the underlying view - Odoo has no
    # native range field type, so it's deliberately left unmapped here rather than
    # forcing it through a field type that doesn't fit. Still readable directly off
    # luxauto_policy_view by SQL for anything that needs it (e.g. a future report).
    policy_status = fields.Char(string='Policy Status', readonly=True)
    quote_id = fields.Char(string='Quote ID', readonly=True)
    premium_amount = fields.Float(string='Premium Amount', digits=(12, 2), readonly=True)
    quote_status = fields.Char(string='Quote Status', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    garaging_state = fields.Char(string='Garaging State', readonly=True)
    application_status = fields.Char(string='Application Status', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_policy_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_policy_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )

    def action_open_cancel_wizard(self):
        # luxauto.policy stays read-only (ADR 0006/0010) - this button doesn't write
        # to the view-backed model itself, it only opens a wizard that calls
        # cancel_policy() (a controlled, SECURITY DEFINER Postgres function).
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'luxauto.cancel.wizard',
            'view_mode': 'form',
            'target': 'new',
            'context': {'default_policy_id': self.policy_id},
        }
