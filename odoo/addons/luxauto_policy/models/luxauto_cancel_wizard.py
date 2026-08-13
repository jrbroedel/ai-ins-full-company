import psycopg2

from odoo import fields, models
from odoo.exceptions import UserError


class LuxautoCancelWizard(models.TransientModel):
    _name = 'luxauto.cancel.wizard'
    _description = 'Cancel a Policy'

    policy_id = fields.Char(string='Policy ID', required=True, readonly=True)
    # ADR 0018: who initiated the cancellation decides whether a filed
    # short-rate table may apply at all, so it is a required input here rather
    # than something the database picks a default for. No default value on
    # purpose - an unconsidered click should not silently record the insured
    # as having asked for a cancellation the company initiated, or vice versa.
    cancellation_type = fields.Selection(
        [('insured_initiated', 'Insured-initiated'), ('company_initiated', 'Company-initiated')],
        string='Initiated By', required=True,
    )
    reason_code = fields.Char(
        string='Reason Code', required=True,
        help='Coded reason, same discipline as the referral matrix - e.g. '
             'CX_INSURED_REQUEST, CX_NONPAYMENT, CX_UNDERWRITING_INELIGIBLE. '
             'Prose belongs in Notes.',
    )
    refund_method = fields.Selection(
        [('pro_rata', 'Pro-rata'), ('short_rate', 'Short-rate')],
        string='Refund Method', required=True, default='pro_rata',
        help='Pro-rata is pure arithmetic and always available. Short-rate '
             'requires a filed short-rate table loaded for this state and '
             'program; if none is loaded the cancellation is refused rather '
             'than estimated.',
    )
    cancelled_at = fields.Datetime(
        string='Effective', help='Leave empty to cancel as of now.',
    )
    notes = fields.Text(string='Notes')

    def action_cancel(self):
        self.ensure_one()
        performed_by = self.env.user.login
        try:
            self.env.cr.execute(
                "SELECT cancel_policy(%s, %s, %s, %s, %s, %s, %s)",
                (
                    self.policy_id,
                    self.cancellation_type,
                    self.reason_code,
                    self.refund_method,
                    self.cancelled_at or None,
                    self.notes or None,
                    performed_by,
                ),
            )
        except psycopg2.Error as exc:
            raise UserError(str(exc).strip()) from exc

        return {'type': 'ir.actions.act_window_close'}
