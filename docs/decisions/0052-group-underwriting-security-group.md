0052 — `group_underwriting` Odoo security group for override UI
Status: Accepted Date: 2026-09-03 Related: 0040 (override UI granted to base.group_user for demo speed). ADRs 0041–0049 live on `demo/investor-preview`.
Context
ADR 0040 granted the underwriter override UI to `base.group_user` explicitly as a demo-speed shortcut. That grant means every internal Odoo user can exercise referral overrides — acceptable for a demo audience, unacceptable for any non-demo use, and easy to forget precisely because the UI works fine as-is.
Decision

1. Create a dedicated `group_underwriting` Odoo security group.
2. Move the ADR 0040 override UI's access (menus, actions, and the record rules on the underlying views) from `base.group_user` to `group_underwriting`.
3. Grant the demo user membership in `group_underwriting` so demo behavior is unchanged.
4. This is a blocking precondition for any non-demo exposure of the override UI; the shortcut it retires must not be reintroduced for convenience.

Consequences

* Authorization matches the underwriting role model instead of "any logged-in user"; future authority-tier UI (senior vs standard underwriter) hangs off this group rather than off ad-hoc checks.
* Demo behavior is unaffected by construction (step 3).
* Small change set: one group definition, access-rights re-pointing, demo-user grant.
