# Template — copy to <customer>-<env>.tfvars (gitignored; customer config stays
# local/private, never committed to this repo).
subscription_id = "00000000-0000-0000-0000-000000000000"
customer        = "contoso"
environment     = "dev"
# Must already exist -- the module reads it, it does not create it.
resource_group_name = "rg-devicecleanup-contoso-dev"

automation_account_name = "aa-devicecleanup-contoso-dev-eastus-1"
key_vault_name          = "kv-devclean-contoso-dev"

secret_retention_days  = 4
soft_delete_after_days = 90
hard_delete_after_days = 120

schedule_enabled = false
enable_apply     = false

# Job alerting (docs/2026-08-11-alerting-request.md), default off.
# alerting_enabled      = true
# alert_email_addresses = ["ops@contoso.com"]
