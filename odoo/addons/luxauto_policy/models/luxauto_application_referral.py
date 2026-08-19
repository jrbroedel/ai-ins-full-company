from odoo import fields, models


class LuxautoApplicationReferral(models.Model):
    _name = 'luxauto.application.referral'
    _description = 'Luxury Auto Application Referral Summary (read-only, backed by luxauto_application_referral_view)'
    _auto = False
    _table = 'luxauto_application_referral_view'
    _rec_name = 'application_id'
    _order = 'evaluated_at desc'

    application_id = fields.Char(string='Application ID', readonly=True)
    # The most-severe action across the current per-rule disposition, derived in
    # the view as max(action_taken) over the latest row per rule - the same value
    # evaluate_application_referrals() returns, computed WITHOUT calling it (that
    # orchestrator writes a decision_log row on every call). See the view comment.
    most_severe_action = fields.Char(string='Most Severe Action', readonly=True)
    fired_rule_count = fields.Integer(string='Fired Rules', readonly=True)
    rule_count = fields.Integer(string='Rules Evaluated', readonly=True)
    evaluated_at = fields.Datetime(string='Last Evaluated', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_application_referral_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_application_referral_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
