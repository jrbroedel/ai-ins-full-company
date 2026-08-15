from odoo import fields, models


class LuxautoPolicyCancellation(models.Model):
    _name = 'luxauto.policy.cancellation'
    _description = 'Luxury Auto Policy Cancellation (read-only, backed by luxauto_policy_cancellation_view)'
    _auto = False
    _table = 'luxauto_policy_cancellation_view'
    # policy_id, not cancellation_id: a cancellation is read as "the
    # cancellation of policy X", and the cancellation_id is a UUID nobody
    # recognises. policy_number would read better still, but the vehicle and
    # driver views deliberately don't join back to policies for it either -
    # matching that rather than widening this view's grain is the consistent
    # choice (ADR 0010's reasoning about not duplicating join paths).
    _rec_name = 'policy_id'
    # Newest first within a policy: a corrected cancellation supersedes an
    # earlier one, so the most recently recorded row is the one usually wanted.
    _order = 'policy_id, created_at desc'

    cancellation_id = fields.Char(string='Cancellation ID', readonly=True)
    policy_id = fields.Char(string='Policy ID', readonly=True)
    # effective_range (the unearned window the refund covers) is a Postgres
    # tstzrange on the underlying view - Odoo has no native range field type,
    # so it stays unmapped here, same as on luxauto.policy. The two scalars
    # derived from it in the view carry what a reader actually needs: when
    # coverage stopped, and whether this row was superseded by a correction.
    cancelled_at = fields.Datetime(string='Cancelled At', readonly=True)
    superseded = fields.Boolean(
        string='Superseded', readonly=True,
        help='True when this cancellation was replaced by a correction. Its '
             'range was emptied rather than closed (ADR 0018 section 6): it '
             'applied for zero time, and its return premium was never owed. '
             'The settlement report excludes these rows for that reason.',
    )
    cancellation_type = fields.Char(string='Initiated By', readonly=True)
    reason_code = fields.Char(string='Reason Code', readonly=True)
    refund_method = fields.Char(string='Refund Method', readonly=True)
    short_rate_factor = fields.Float(string='Short-Rate Factor', digits=(6, 4), readonly=True)
    short_rate_basis = fields.Char(string='Short-Rate Basis', readonly=True)
    unearned_premium = fields.Float(string='Unearned Premium', digits=(12, 2), readonly=True)
    # Signed, and negative when money is owed back to the insured - the sign
    # is the direction, not a display quirk (ADR 0018 section 3).
    return_premium = fields.Float(string='Return Premium', digits=(12, 2), readonly=True)
    notes = fields.Text(readonly=True)
    performed_by = fields.Char(string='Performed By', readonly=True)
    created_at = fields.Datetime(string='Recorded At', readonly=True)

    def init(self):
        # See luxauto_insured.py's init() for why this doesn't (re)create the view.
        self.env.cr.execute("SELECT to_regclass('public.luxauto_policy_cancellation_view')")
        if not self.env.cr.fetchone()[0]:
            raise ValueError(
                "luxauto_policy_cancellation_view does not exist - apply "
                "schemas/db/postgresql_schema.sql before installing luxauto_policy."
            )
