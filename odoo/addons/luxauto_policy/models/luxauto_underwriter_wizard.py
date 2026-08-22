import psycopg2

from odoo import fields, models
from odoo.exceptions import UserError


class LuxautoUnderwriterAddWizard(models.TransientModel):
    _name = 'luxauto.underwriter.add.wizard'
    _description = 'Add an Underwriter to the Roster'

    name = fields.Char(required=True)
    authority_level = fields.Selection(
        [('standard', 'Standard'), ('senior', 'Senior')],
        string='Authority Level', required=True, default='standard')

    def action_add(self):
        self.ensure_one()
        try:
            self.env.cr.execute(
                "SELECT add_underwriter(%s, %s)", (self.name, self.authority_level))
            self.env.cr.fetchone()
        except psycopg2.Error as exc:
            raise UserError(str(exc).strip()) from exc
        return {
            'type': 'ir.actions.act_window',
            'name': 'Underwriters',
            'res_model': 'luxauto.underwriter',
            'view_mode': 'list,form',
            'target': 'current',
        }


class LuxautoUnderwriterUpdateWizard(models.TransientModel):
    _name = 'luxauto.underwriter.update.wizard'
    _description = 'Update an Underwriter (promote/demote/(de)activate/rename)'

    underwriter = fields.Many2one('luxauto.underwriter', string='Underwriter', required=True)
    # All optional: leave blank to keep unchanged (update_underwriter uses
    # COALESCE, NULL = unchanged). active is a tri-state Selection rather than a
    # Boolean because a plain Odoo Boolean cannot express "leave unchanged".
    new_name = fields.Char(string='New Name', help="Leave blank to keep the current name.")
    new_authority_level = fields.Selection(
        [('standard', 'Standard'), ('senior', 'Senior')],
        string='New Authority Level', help="Leave blank to keep the current authority.")
    active_action = fields.Selection(
        [('none', 'No change'), ('activate', 'Activate'), ('deactivate', 'Deactivate')],
        string='Active Status', required=True, default='none')

    def action_update(self):
        self.ensure_one()
        p_name = self.new_name or None
        p_authority = self.new_authority_level or None
        if self.active_action == 'activate':
            p_active = True
        elif self.active_action == 'deactivate':
            p_active = False
        else:
            p_active = None
        try:
            self.env.cr.execute(
                "SELECT update_underwriter(%s, %s, %s, %s)",
                (self.underwriter.underwriter_id, p_name, p_authority, p_active),
            )
            self.env.cr.fetchone()
        except psycopg2.Error as exc:
            # update_underwriter raises UPDATE_UNDERWRITER_NO_CHANGES (all blank),
            # UPDATE_UNDERWRITER_NAME_REQUIRED (blank name), etc. - surface cleanly.
            raise UserError(str(exc).strip()) from exc
        return {
            'type': 'ir.actions.act_window',
            'name': 'Underwriters',
            'res_model': 'luxauto.underwriter',
            'view_mode': 'list,form',
            'target': 'current',
        }
