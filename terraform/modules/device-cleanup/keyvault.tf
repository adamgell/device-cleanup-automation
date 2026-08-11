# Key Vault for short-lived BitLocker/LAPS backups. Purge protection stays OFF
# on purpose: the runbook deletes + purges secrets past their retention window
# (customer requirement: no long-term secret storage, ~2-5 day rollback only).

resource "azurerm_key_vault" "secrets" {
  count = var.backup_enabled ? 1 : 0

  name                       = var.key_vault_name
  location                   = var.location
  resource_group_name        = data.azurerm_resource_group.target.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = local.base_tags
}

resource "azurerm_role_assignment" "kv_secrets_officer" {
  count = var.backup_enabled ? 1 : 0

  scope                = azurerm_key_vault.secrets[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_automation_account.this.identity[0].principal_id
}
