from odoo import fields, models


class LuxautoDecisionLog(models.Model):
    _name = 'luxauto.decision.log'
    _description = 'Luxury Auto Referral Decision Log (read-only detail, backed by luxauto_decision_log_view)'
    _auto = False
    _table = 'luxauto_decision_log_view'
    _rec_name = 'rule_id'
    # Grouped by application, newest evaluation first within it - the append-only
    # log accumulates re-evaluations, and the most recent rows are the current
    # disposition (the summary model collapses to that; this keeps every row).
    _order = 'application_id, created_at desc'

    log_id = fields.Char(string='Log ID', readonly=True)
    application_id = fields.Char(string='Application ID', readonly=True)
    rule_id = fields.Char(string='Rule ID', readonly=True)
    reason_code = fields.Char(string='Reason Code', readonly=True)
    action_taken = fields.Char(string='Action Taken', readonly=True)
    # False on a non-firing audit row: every rule evaluation logs a row whether
    # its trigger matched or not (decision_log is deliberately unredacted).
    fired = fields.Boolean(string='Fired', readonly=True)
    decided_by = fields.Char(string='Decided By', readonly=True)
    notes = fields.Text(readonly=True)
    created_at = fields.Datetime(string='Evaluated At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_decision_log_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_decision_log_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
