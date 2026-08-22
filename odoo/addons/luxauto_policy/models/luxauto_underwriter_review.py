from odoo import fields, models


class LuxautoUnderwriterReview(models.Model):
    _name = 'luxauto.underwriter.review'
    _description = 'Luxury Auto Underwriter Review Queue (read-only, backed by luxauto_underwriter_review_view)'
    _auto = False
    _table = 'luxauto_underwriter_review_view'
    _rec_name = 'application_id'
    # Pending first (a NULL overridden_at sorts last on DESC would bury the
    # actionable ones), then newest evaluation - but keep it simple and stable:
    # newest evaluation first, and the Status column / a search filter separate
    # pending from released.
    _order = 'evaluated_at desc'

    application_id = fields.Char(string='Application ID', readonly=True)
    most_severe_action = fields.Char(string='Disposition', readonly=True)
    evaluated_at = fields.Datetime(string='Evaluated At', readonly=True)
    fired_rule_count = fields.Integer(string='Fired Rules', readonly=True)
    rule_count = fields.Integer(string='Rules Evaluated', readonly=True)
    # 'pending' (no valid override yet) or 'released' (a supervised override
    # matching this exact disposition + evaluation exists).
    override_status = fields.Char(string='Status', readonly=True)
    override_id = fields.Char(string='Override ID', readonly=True)
    override_reason = fields.Text(string='Override Reason', readonly=True)
    overridden_at = fields.Datetime(string='Overridden At', readonly=True)
    authorized_by_name = fields.Char(string='Authorized By', readonly=True)
    authorized_by_authority = fields.Char(string='Authorizer Authority', readonly=True)

    def action_open_override_wizard(self):
        # Opens the override wizard pre-filled with THIS row's application and its
        # exact current disposition - authorize_referral_override() rejects a
        # disposition that does not match the current one, so pre-filling (rather
        # than free-typing) is both friendlier and correct.
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': 'Authorize Override',
            'res_model': 'luxauto.override.wizard',
            'view_mode': 'form',
            'target': 'new',
            'context': {
                'default_application_id': self.application_id,
                'default_overridden_action': self.most_severe_action,
            },
        }

    def init(self):
        self.env.cr.execute("SELECT to_regclass('public.luxauto_underwriter_review_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_underwriter_review_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
