# Pretty HTML alert emails (docs/ROADMAP.md #5, email half): action group
# webhook receiver -> Logic App (parses common alert schema, composes
# severity-styled HTML) -> Azure Communication Services email send.
# No secrets anywhere: the Logic App's managed identity holds Contributor on
# the ACS resource and the HTTP action uses Entra auth (audience
# https://communication.azure.com). Sender is the ACS Azure-managed domain
# (DoNotReply@<guid>.azurecomm.net).

locals {
  acs_endpoint = var.pretty_email_enabled ? "https://acs-devicecleanup-${var.environment}.communication.azure.com" : null

  # Log Analytics customer GUID for the query API. Attachments require the
  # module-created workspace (BYO workspace id carries no GUID we can query).
  pe_ws_guid = try(azurerm_log_analytics_workspace.alerting[0].workspace_id, null)
  pe_nl      = "decodeUriComponent('%0A')"

  # Logic App expressions evaluated per-alert at run time.
  pe_essentials = "triggerBody()?['data']?['essentials']"
  pe_severity   = "coalesce(triggerBody()?['data']?['essentials']?['severity'], 'Sev4')"
  pe_condition  = "coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], 'Fired')"
  pe_color      = "if(equals(${local.pe_condition}, 'Resolved'), '#1d9e75', if(equals(${local.pe_severity}, 'Sev1'), '#a32d2d', if(equals(${local.pe_severity}, 'Sev2'), '#ba7517', '#185fa5')))"

  pe_html = <<-HTML
    <div style="font-family:Segoe UI,Arial,sans-serif;max-width:640px;margin:0 auto;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden">
      <div style="background:@{${local.pe_color}};color:#ffffff;padding:16px 24px">
        <div style="font-size:13px;opacity:.85">Device cleanup automation &middot; @{${local.pe_severity}} &middot; @{${local.pe_condition}}</div>
        <div style="font-size:20px;font-weight:600;margin-top:4px">@{coalesce(${local.pe_essentials}?['alertRule'], 'Alert')}</div>
      </div>
      <div style="padding:20px 24px">
        <p style="font-size:14px;color:#333333;margin:0 0 16px">@{coalesce(${local.pe_essentials}?['description'], '')}</p>
        <table style="width:100%;font-size:13px;color:#333333;border-collapse:collapse">
          <tr><td style="padding:6px 0;color:#777777;width:140px">Fired time</td><td>@{coalesce(${local.pe_essentials}?['firedDateTime'], ${local.pe_essentials}?['resolvedDateTime'], '')}</td></tr>
          <tr><td style="padding:6px 0;color:#777777">Environment</td><td>${var.customer} / ${var.environment}</td></tr>
          <tr><td style="padding:6px 0;color:#777777">Runbook</td><td>${var.runbook_name}</td></tr>
          <tr><td style="padding:6px 0;color:#777777">Result count</td><td>@{coalesce(string(triggerBody()?['data']?['alertContext']?['condition']?['allOf']?[0]?['metricValue']), '-')}</td></tr>
        </table>
        <div style="margin-top:20px">
          <a href="@{coalesce(triggerBody()?['data']?['alertContext']?['condition']?['allOf']?[0]?['linkToFilteredSearchResultsUI'], 'https://portal.azure.com')}"
             style="background:#185fa5;color:#ffffff;text-decoration:none;font-size:14px;padding:10px 18px;border-radius:4px;display:inline-block">View query results</a>
        </div>
      </div>
      <div style="padding:12px 24px;border-top:1px solid #eeeeee;font-size:12px;color:#999999">
        Sent by the device-cleanup pretty-email pipeline (ACS). DryRun runs report would-be actions only.
      </div>
    </div>
  HTML
}

resource "azurerm_email_communication_service" "pretty" {
  count = var.pretty_email_enabled ? 1 : 0

  name                = "acsmail-devicecleanup-${var.environment}"
  resource_group_name = data.azurerm_resource_group.target.name
  data_location       = "United States"

  tags = local.base_tags
}

resource "azurerm_email_communication_service_domain" "pretty" {
  count = var.pretty_email_enabled ? 1 : 0

  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.pretty[0].id
  domain_management = "AzureManaged"
}

resource "azurerm_communication_service" "pretty" {
  count = var.pretty_email_enabled ? 1 : 0

  name                = "acs-devicecleanup-${var.environment}"
  resource_group_name = data.azurerm_resource_group.target.name
  data_location       = "United States"

  tags = local.base_tags
}

resource "azurerm_communication_service_email_domain_association" "pretty" {
  count = var.pretty_email_enabled ? 1 : 0

  communication_service_id = azurerm_communication_service.pretty[0].id
  email_service_domain_id  = azurerm_email_communication_service_domain.pretty[0].id
}

resource "azurerm_logic_app_workflow" "pretty_email" {
  count = var.pretty_email_enabled ? 1 : 0

  name                = "logic-devicecleanup-prettymail-${var.environment}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name

  identity {
    type = "SystemAssigned"
  }

  tags = local.base_tags
}

resource "azurerm_role_assignment" "pretty_email_acs" {
  count = var.pretty_email_enabled ? 1 : 0

  scope                = azurerm_communication_service.pretty[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_logic_app_workflow.pretty_email[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "pretty_email_law" {
  count = var.pretty_email_enabled ? 1 : 0

  scope                = local.log_analytics_workspace_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_logic_app_workflow.pretty_email[0].identity[0].principal_id
}

resource "azurerm_logic_app_trigger_http_request" "pretty_email" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "common-alert-schema"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id
  schema       = "{}"
}

# Fetch recent job-stream text (failure attachment source).
resource "azurerm_logic_app_action_custom" "pretty_email_get_streams" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "get-job-streams"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method  = "POST"
      uri     = "https://api.loganalytics.io/v1/workspaces/${local.pe_ws_guid}/query"
      headers = { "Content-Type" = "application/json" }
      body = {
        query = "AzureDiagnostics | where Category == 'JobStreams' and TimeGenerated > ago(2h) | order by TimeGenerated asc | project TimeGenerated, JobId_g, ResultDescription"
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://api.loganalytics.io"
      }
    }
    runAfter = {}
  })
}

# Fetch the latest run's device-results JSON array (digest CSV source).
resource "azurerm_logic_app_action_custom" "pretty_email_get_devices" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "get-device-json"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method  = "POST"
      uri     = "https://api.loganalytics.io/v1/workspaces/${local.pe_ws_guid}/query"
      headers = { "Content-Type" = "application/json" }
      body = {
        query = "AzureDiagnostics | where Category == 'JobStreams' and StreamType_s == 'Output' and TimeGenerated > ago(6h) and ResultDescription startswith '[CSVROW]' | where JobId_g == toscalar(AzureDiagnostics | where Category == 'JobStreams' and StreamType_s == 'Output' and TimeGenerated > ago(6h) and ResultDescription startswith '[CSVROW]' | top 1 by TimeGenerated desc | project JobId_g) | order by TimeGenerated asc | project ResultDescription"
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://api.loganalytics.io"
      }
    }
    runAfter = {}
  })
}

resource "azurerm_logic_app_action_custom" "pretty_email_log_lines" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "select-log-lines"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Select"
    inputs = {
      from   = "@coalesce(body('get-job-streams')?['tables']?[0]?['rows'], json('[]'))"
      select = "@concat(item()[0], '  ', item()[2])"
    }
    runAfter = {
      "get-job-streams" = ["Succeeded", "Failed"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "pretty_email_csv_lines" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "select-csv-lines"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Select"
    inputs = {
      from   = "@coalesce(body('get-device-json')?['tables']?[0]?['rows'], json('[]'))"
      select = "@substring(item()[0], 9)"
    }
    runAfter = {
      "get-device-json" = ["Succeeded", "Failed"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "pretty_email_send" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "send-acs-email"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method = "POST"
      uri    = "${local.acs_endpoint}/emails:send"
      queries = {
        "api-version" = "2023-03-31"
      }
      headers = {
        "Content-Type" = "application/json"
      }
      body = {
        senderAddress = "DoNotReply@${azurerm_email_communication_service_domain.pretty[0].from_sender_domain}"
        recipients = {
          to = [for r in var.pretty_email_recipients : { address = r }]
        }
        content = {
          subject = "@{concat('Device Cleanup ', ${local.pe_condition}, ' (', ${local.pe_severity}, '): ', coalesce(${local.pe_essentials}?['alertRule'], 'alert'))}"
          html    = local.pe_html
        }
        attachments = "@if(contains(coalesce(${local.pe_essentials}?['alertRule'], ''), 'job-failed'), json(concat('[{\"name\":\"job-streams.txt\",\"contentType\":\"text/plain\",\"contentInBase64\":\"', base64(join(coalesce(body('select-log-lines'), json('[]')), ${local.pe_nl})), '\"}]')), if(contains(coalesce(${local.pe_essentials}?['alertRule'], ''), 'run-digest'), json(concat('[{\"name\":\"devices.csv\",\"contentType\":\"text/csv\",\"contentInBase64\":\"', base64(concat(join(coalesce(body('select-csv-lines'), json('[]')), ${local.pe_nl}))), '\"}]')), json('[]')))"
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://communication.azure.com"
      }
      retryPolicy = {
        type     = "exponential"
        count    = 3
        interval = "PT20S"
      }
    }
    runAfter = {
      "select-log-lines" = ["Succeeded", "Failed", "Skipped"]
      "select-csv-lines" = ["Succeeded", "Failed", "Skipped"]
    }
  })
}
