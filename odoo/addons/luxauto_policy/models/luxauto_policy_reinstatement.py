from odoo import fields, models


class LuxautoPolicyReinstatement(models.Model):
    _name = 'luxauto.policy.reinstatement'
    _description = 'Luxury Auto Policy Reinstatement (read-only, backed by luxauto_policy_reinstatement_view)'
    _auto = False
    _table = 'luxauto_policy_reinstatement_view'
    # The new policy is what a reader recognises a reinstatement by ("the
    # reinstatement that produced POL-...-NEW"); reinstatement_id is a UUID nobody
    # reads. Same choice the cancellation model made with policy_id over the
    # cancellation UUID.
    _rec_name = 'new_policy_number'
    # Newest first: the most recently recorded reinstatement is usually the one
    # being looked at, matching the cancellation view's created_at desc ordering.
    _order = 'created_at desc'

    reinstatement_id = fields.Char(string='Reinstatement ID', readonly=True)
    new_policy_id = fields.Char(string='New Policy ID', readonly=True)
    new_policy_number = fields.Char(string='New Policy Number', readonly=True)
    prior_policy_id = fields.Char(string='Prior Policy ID', readonly=True)
    prior_policy_number = fields.Char(string='Prior Policy Number', readonly=True)
    cancellation_id = fields.Char(string='Source Cancellation ID', readonly=True)
    # ADR 0024: the single instant the prior policy's coverage lapsed, which is
    # also the new policy's backdated inception - zero gap is the whole point, so
    # this is one date, not a start/end pair.
    gap_start = fields.Datetime(string='Coverage Lapsed / Backdated Inception', readonly=True)
    attestation_reference = fields.Char(string='Attestation Reference', readonly=True)
    performed_by = fields.Char(string='Performed By', readonly=True)
    created_at = fields.Datetime(string='Recorded At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_policy_reinstatement_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_policy_reinstatement_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
