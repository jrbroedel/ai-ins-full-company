import psycopg2

from odoo import fields, models
from odoo.exceptions import UserError


class LuxautoOverrideWizard(models.TransientModel):
    _name = 'luxauto.override.wizard'
    _description = 'Authorize a Supervised Referral Override'

    # Pre-filled from the review-queue row (readonly): the override must target
    # the application's ACTUAL current disposition - the DB function enforces that.
    application_id = fields.Char(string='Application ID', required=True, readonly=True)
    overridden_action = fields.Char(string='Disposition Being Overridden', required=True, readonly=True)
    # Picked from the roster; only active underwriters are offered (an inactive
    # one is refused by the DB anyway, but do not offer what cannot work).
    underwriter = fields.Many2one(
        'luxauto.underwriter', string='Authorizing Underwriter', required=True,
        domain=[('is_active', '=', True)])
    reason = fields.Text(string='Rationale', required=True,
                         help="Why this flagged application is being released. Required "
                              "(the referral_overrides record is a permanent audit row).")

    def action_authorize(self):
        self.ensure_one()
        try:
            self.env.cr.execute(
                "SELECT authorize_referral_override(%s, %s, %s, %s)",
                (self.application_id, self.overridden_action, self.reason,
                 self.underwriter.underwriter_id),
            )
            self.env.cr.fetchone()
        except psycopg2.Error as exc:
            # authorize_referral_override / its trigger raise plain exceptions
            # (OVERRIDE_SENIOR_AUTHORITY_REQUIRED, OVERRIDE_AUTHORIZER_INACTIVE,
            # OVERRIDE_DISPOSITION_MISMATCH, ...) - surface the message, not a raw
            # traceback, exactly as the bind/cancel wizards do.
            raise UserError(str(exc).strip()) from exc

        # Land back on the review queue so the row is visibly now 'released'.
        return {
            'type': 'ir.actions.act_window',
            'name': 'Underwriter Review Queue',
            'res_model': 'luxauto.underwriter.review',
            'view_mode': 'list,form',
            'target': 'current',
        }
