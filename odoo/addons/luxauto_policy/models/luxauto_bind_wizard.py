import psycopg2

from odoo import fields, models
from odoo.exceptions import UserError


class LuxautoBindWizard(models.TransientModel):
    _name = 'luxauto.bind.wizard'
    _description = 'Bind a Quote into a Policy'

    quote_id = fields.Char(string='Quote ID', required=True,
                            help="The pipeline's quote_id (UUID) - must be in 'issued' status.")
    policy_number = fields.Char(required=True)

    def action_bind(self):
        self.ensure_one()
        performed_by = self.env.user.login
        try:
            self.env.cr.execute(
                "SELECT bind_policy(%s, %s, %s)",
                (self.quote_id, self.policy_number, performed_by),
            )
            new_policy_id = self.env.cr.fetchone()[0]
        except psycopg2.Error as exc:
            # bind_policy (schemas/db/postgresql_schema.sql) raises a plain exception
            # for bad state (quote not issued, quote already has a policy) rather
            # than letting a bad call fail partway - surface that message directly
            # instead of a raw traceback.
            raise UserError(str(exc).strip()) from exc

        policy = self.env['luxauto.policy'].search(
            [('policy_id', '=', str(new_policy_id))], limit=1
        )
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'luxauto.policy',
            'view_mode': 'form',
            'res_id': policy.id,
            'target': 'current',
        }
