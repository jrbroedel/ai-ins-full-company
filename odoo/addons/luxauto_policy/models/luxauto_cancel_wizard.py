import psycopg2

from odoo import fields, models
from odoo.exceptions import UserError


class LuxautoCancelWizard(models.TransientModel):
    _name = 'luxauto.cancel.wizard'
    _description = 'Cancel a Policy'

    policy_id = fields.Char(string='Policy ID', required=True, readonly=True)
    notes = fields.Text(string='Cancellation Reason')

    def action_cancel(self):
        self.ensure_one()
        performed_by = self.env.user.login
        try:
            self.env.cr.execute(
                "SELECT cancel_policy(%s, %s, %s)",
                (self.policy_id, performed_by, self.notes or None),
            )
        except psycopg2.Error as exc:
            raise UserError(str(exc).strip()) from exc

        return {'type': 'ir.actions.act_window_close'}
