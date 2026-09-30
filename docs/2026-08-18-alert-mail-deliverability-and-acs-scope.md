# Alert mail deliverability + ACS role scope

Deployment considerations: alert email may land in the recipient's **spam** folder,
and the Logic App identity may hold **Contributor** on the ACS resource.

## 1. Deliverability

Cause: `domain_management = "AzureManaged"` sends as `DoNotReply@<guid>.azurecomm.net`.
That domain has no relationship to the customer, no customer SPF/DKIM alignment, and shared
reputation. Exchange Online routinely junks it. This is a property of the sender domain, not
a tunable — no ACS-side setting fixes it.

### Option A — reuse an Exchange-Online-verified domain (no DNS work)
`email_domain_management = "CustomerManagedInExchangeOnline"` with
`email_custom_domain_name = "example.org"`. ACS accepts a domain already verified
in the customer's M365 tenant; existing SPF/DKIM apply. Sender becomes
`DoNotReply@example.org`.

Before deployment, verify the chosen domain in the target tenant using Graph
`/v1.0/domains`; check `isVerified` and `supportedServices` for email support.
The example domain above is a placeholder, not a verified tenant domain.

Cutover steps:
1. A tenant admin authorizes the ACS-to-Exchange-Online domain connection once — this is
   a tenant-side consent, not something Terraform performs.
2. Apply with the two variables above. The `AzureManagedDomain` resource is replaced by the
   customer-managed one, so expect a destroy/create on the domain and its association.
3. Fire one real alert and confirm **inbox** placement, not just a successful send.

### Option B — customer-managed subdomain (fallback: customer has no Exchange Online)
`email_domain_management = "CustomerManaged"` with e.g. `notify.example.org`.
Terraform outputs `email_domain_verification_records`; the customer publishes the TXT/SPF/DKIM
records, then verification completes. Keeps automation mail off the primary domain's
reputation. Costs a DNS change request.

### Option C — transport-rule allowlist (stopgap only)
Exchange Online mail-flow rule bypassing spam filtering for the exact
`<guid>.azurecomm.net` sender. Fast, but it is an allowlist entry for a shared Microsoft
domain — weaker than A or B and worth retiring once one of them lands. Acceptable to unblock
the current dev cycle, not for prod.

Whichever lands, verify by triggering one real alert and confirming inbox placement — the
send succeeding in the Logic App run history proves nothing about where it went.

## 2. ACS role scope (prod)

`acs_email_role_definition_name` now controls the role granted to the Logic App identity on
the ACS resource; it defaults to `Contributor`, which is what Microsoft documents for
Entra-authenticated email send and the only combination verified working here.

Contributor on that resource also carries write, delete, and `ListKeys` — i.e. the identity
can regenerate the ACS access keys. Scoped to a single resource, so blast radius is one ACS
instance, but it is more than a send needs.

For prod: define a custom role scoped to the ACS resource with the minimum actions, **verify
a live test send with it before cutover**, then pass its name via
`acs_email_role_definition_name`. The provider exposes no `dataActions` for email send, so the
minimal working set must be established empirically, not read off the docs. The one built-in
alternative, *Communication and Email Service Owner*, is not an improvement — it is broader on
the Email Services side.
