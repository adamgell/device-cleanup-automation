# Graph application-permission grants for the Automation account's
# system-assigned managed identity. Replaces the delegated -Scopes consent of
# the original interactive script. Requires the deployer to hold a privileged
# directory role (Privileged Role Administrator or Global Administrator).

data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
}

resource "azuread_app_role_assignment" "graph" {
  for_each = toset(var.graph_app_roles)

  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value]
  principal_object_id = azurerm_automation_account.this.identity[0].principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
