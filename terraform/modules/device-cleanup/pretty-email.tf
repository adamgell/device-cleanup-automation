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

  # Which rule fired. essentials.alertId is the ARM resource id and carries the
  # rule's *resource* name; essentials.alertRule carries the *display* name.
  # Matching on alertRule alone was the original bug -- it tested for
  # 'run-digest' against text reading "run completed", so no alert ever matched
  # and no email ever carried its attachment.
  # The alert's evaluation window can still contain an EARLIER run's counters,
  # so "latest run in the last 6h" is not necessarily the run that tripped the
  # rule. Anchoring every lookup at or before firedDateTime makes the email
  # describe the run that actually fired it. (Seen 2026-08-17: the 19:21 alert
  # was raised on the 19:05 run's ToDelete=142 while the 19:17 run showed 30.)
  pe_fired = "coalesce(triggerBody()?['data']?['essentials']?['firedDateTime'], utcNow())"

  pe_alert_id   = "toLower(coalesce(triggerBody()?['data']?['essentials']?['alertId'], ''))"
  pe_alert_name = "toLower(coalesce(triggerBody()?['data']?['essentials']?['alertRule'], ''))"
  pe_is_jobfail = "or(contains(${local.pe_alert_id}, 'job-failed'), contains(${local.pe_alert_name}, 'job failed'))"
  pe_is_delete  = "or(contains(${local.pe_alert_id}, 'delete-threshold'), contains(${local.pe_alert_name}, 'would-delete'))"
  pe_is_digest  = "or(contains(${local.pe_alert_id}, 'run-digest'), contains(${local.pe_alert_name}, 'run completed'))"

  # RUN SUMMARY counters, parsed from the runbook's [RUNSUMMARY] JSON line.
  pe_sum      = "outputs('parse-run-summary')"
  pe_is_dry   = "equals(coalesce(${local.pe_sum}?['DryRun'], true), true)"
  pe_verb_dis = "if(${local.pe_is_dry}, 'Would disable', 'Disabled')"
  pe_verb_del = "if(${local.pe_is_dry}, 'Would delete', 'Deleted')"

  pe_html = <<-HTML
    <div style="font-family:Segoe UI,Arial,sans-serif;max-width:640px;margin:0 auto;border:1px solid #e0e0e0;border-radius:8px;overflow:hidden">
      <div style="background:@{${local.pe_color}};color:#ffffff;padding:16px 24px">
        <div style="font-size:13px;opacity:.85">Device cleanup automation &middot; @{${local.pe_severity}} &middot; @{${local.pe_condition}}</div>
        <div style="font-size:20px;font-weight:600;margin-top:4px">@{coalesce(${local.pe_essentials}?['alertRule'], 'Alert')}</div>
      </div>
      <div style="padding:0 24px">
        <div style="margin:16px 0 0;padding:10px 14px;border-radius:4px;font-size:14px;font-weight:600;background:@{if(${local.pe_is_dry}, '#e8f6f0', '#fdeaea')};color:@{if(${local.pe_is_dry}, '#12734f', '#8f2323')}">
          @{if(${local.pe_is_dry}, 'DRY RUN &mdash; nothing was changed', 'LIVE RUN &mdash; these changes were applied')}
        </div>
      </div>
      <div style="padding:16px 24px 20px">
        <p style="font-size:15px;color:#222222;margin:0 0 4px;line-height:1.5">
          Checked <b>@{coalesce(${local.pe_sum}?['Total'], '?')}</b> stale device objects.
          <b>@{coalesce(${local.pe_sum}?['ToDisable'], 0)}</b> @{if(${local.pe_is_dry}, 'would be disabled', 'were disabled')},
          <b>@{coalesce(${local.pe_sum}?['ToDelete'], 0)}</b> @{if(${local.pe_is_dry}, 'would be deleted', 'were deleted')}.
        </p>
        <p style="font-size:13px;color:#666666;margin:0 0 18px">@{coalesce(${local.pe_essentials}?['description'], '')}</p>

        <table style="width:100%;font-size:13px;color:#333333;border-collapse:collapse">
          <tr><td colspan="2" style="padding:10px 0 4px;font-size:12px;font-weight:600;color:#999999;letter-spacing:.4px">WHAT HAPPENED</td></tr>
          <tr><td style="padding:5px 0;color:#666666;width:230px">Devices checked</td><td><b>@{coalesce(${local.pe_sum}?['Total'], '?')}</b></td></tr>
          <tr style="background:#fafafa"><td style="padding:5px 0;color:#666666">@{${local.pe_verb_dis}} (reversible)</td><td><b>@{coalesce(${local.pe_sum}?['ToDisable'], 0)}</b></td></tr>
          <tr><td style="padding:5px 0;color:#666666">@{${local.pe_verb_del}} (permanent)</td><td><b style="color:@{if(greater(coalesce(${local.pe_sum}?['ToDelete'], 0), 0), '#a32d2d', '#333333')}">@{coalesce(${local.pe_sum}?['ToDelete'], 0)}</b></td></tr>
          <tr><td colspan="2" style="padding:12px 0 4px;font-size:12px;font-weight:600;color:#999999;letter-spacing:.4px">SAFETY RAILS</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Kept &mdash; Autopilot device protected</td><td>@{coalesce(${local.pe_sum}?['AutopilotProtected'], 0)}</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Kept &mdash; serial matches live hardware</td><td>@{coalesce(${local.pe_sum}?['ApRecordsProtectedBySerial'], 0)}</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Autopilot registrations removed</td><td>@{coalesce(${local.pe_sum}?['AutopilotDeleted'], 0)}</td></tr>
          <tr><td colspan="2" style="padding:12px 0 4px;font-size:12px;font-weight:600;color:#999999;letter-spacing:.4px">PROBLEMS</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Key Vault backup failures</td><td><b style="color:@{if(greater(coalesce(${local.pe_sum}?['BackupFailed'], 0), 0), '#a32d2d', '#333333')}">@{coalesce(${local.pe_sum}?['BackupFailed'], 0)}</b></td></tr>
          <tr><td style="padding:5px 0;color:#666666">Errors</td><td><b style="color:@{if(greater(coalesce(${local.pe_sum}?['Errors'], 0), 0), '#a32d2d', '#333333')}">@{coalesce(${local.pe_sum}?['Errors'], 0)}</b></td></tr>
          <tr><td colspan="2" style="padding:12px 0 4px;font-size:12px;font-weight:600;color:#999999;letter-spacing:.4px">RUN</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Run id</td><td>@{coalesce(${local.pe_sum}?['RunId'], '-')}</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Fired</td><td>@{coalesce(${local.pe_essentials}?['firedDateTime'], ${local.pe_essentials}?['resolvedDateTime'], '')}</td></tr>
          <tr><td style="padding:5px 0;color:#666666">Tenant / environment</td><td>${var.customer} / ${var.environment}</td></tr>
        </table>

        <div style="margin-top:18px;padding:12px 14px;background:#f4f7fb;border-left:3px solid #185fa5;font-size:13px;color:#333333;line-height:1.5">
          <b>What to do next.</b>
          @{if(${local.pe_is_delete}, concat('Open the attached delete-candidates.csv and confirm every row is genuinely dead hardware before anyone runs this for real. Check the IsAutopilot and ZtdId columns especially -- deleting the Autopilot registration of a machine that is still in service means it cannot re-enrol.'), if(${local.pe_is_jobfail}, 'The run did not finish. Read the attached job-streams.txt, fix the cause, and re-run in dry run before scheduling.', if(${local.pe_is_digest}, 'Routine completion notice. Skim the numbers above; the attached devices.csv is the full evidence list for this run.', 'Review the run output in the Automation account.')))}
        </div>

        <p style="margin:14px 0 0;font-size:13px;color:#555555">
          @{if(${local.pe_is_delete}, 'Attached: <b>delete-candidates.csv</b> &mdash; only the devices on the delete list, with age, owner, enabled state, Autopilot status and the reason each landed there.', if(${local.pe_is_digest}, 'Attached: <b>devices.csv</b> &mdash; every device this run evaluated.', if(${local.pe_is_jobfail}, 'Attached: <b>job-streams.txt</b> &mdash; the full run log.', '')))}
        </p>

        <div style="margin-top:20px">
          <a href="@{coalesce(triggerBody()?['data']?['alertContext']?['condition']?['allOf']?[0]?['linkToFilteredSearchResultsUI'], 'https://portal.azure.com')}"
             style="background:#185fa5;color:#ffffff;text-decoration:none;font-size:14px;padding:10px 18px;border-radius:4px;display:inline-block">Open the full run log</a>
        </div>
      </div>
      <div style="padding:12px 24px;border-top:1px solid #eeeeee;font-size:12px;color:#999999">
        Automated message from the Presbyterian Homes device cleanup automation.
        A dry run reports what it <i>would</i> do and changes nothing.
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

  name              = var.email_domain_management == "AzureManaged" ? "AzureManagedDomain" : var.email_custom_domain_name
  email_service_id  = azurerm_email_communication_service.pretty[0].id
  domain_management = var.email_domain_management
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

  lifecycle {
    precondition {
      condition     = length(var.pretty_email_recipients) > 0
      error_message = "pretty_email_enabled is true but pretty_email_recipients is empty — the composed alert mail would have no To: address."
    }
    precondition {
      condition     = var.email_domain_management == "AzureManaged" || var.email_custom_domain_name != null
      error_message = "email_domain_management is customer-managed but email_custom_domain_name was not set."
    }
  }

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
  role_definition_name = var.acs_email_role_definition_name
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

# Fetch the latest run's [RUNSUMMARY] JSON line -- the counters the email shows.
resource "azurerm_logic_app_action_custom" "pretty_email_get_summary" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "get-run-summary"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method  = "POST"
      uri     = "https://api.loganalytics.io/v1/workspaces/${local.pe_ws_guid}/query"
      headers = { "Content-Type" = "application/json" }
      body = {
        query = "AzureDiagnostics | where Category == 'JobStreams' and StreamType_s == 'Output' and TimeGenerated > ago(6h) and TimeGenerated <= todatetime('@{${local.pe_fired}}') and ResultDescription startswith '[RUNSUMMARY]' | top 1 by TimeGenerated desc | project ResultDescription"
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://api.loganalytics.io"
      }
    }
    runAfter = {}
  })
}

# '[RUNSUMMARY] ' is 13 characters; the remainder is the counter object.
resource "azurerm_logic_app_action_custom" "pretty_email_parse_summary" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "parse-run-summary"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type   = "Compose"
    inputs = "@json(substring(coalesce(body('get-run-summary')?['tables']?[0]?['rows']?[0]?[0], '[RUNSUMMARY] {}'), 13))"
    runAfter = {
      "get-run-summary" = ["Succeeded", "Failed"]
    }
  })
}

# Delete-candidate rows only, for the would-delete alert's CSV attachment.
# Stage is the only column that ever holds the literal "HardDelete", so matching
# the quoted token is unambiguous; the header row is matched separately.
resource "azurerm_logic_app_action_custom" "pretty_email_get_delete_rows" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "get-delete-rows"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Http"
    inputs = {
      method  = "POST"
      uri     = "https://api.loganalytics.io/v1/workspaces/${local.pe_ws_guid}/query"
      headers = { "Content-Type" = "application/json" }
      body = {
        query = "let fired = todatetime('@{${local.pe_fired}}'); let latest = toscalar(AzureDiagnostics | where Category == 'JobStreams' and StreamType_s == 'Output' and TimeGenerated > ago(6h) and TimeGenerated <= fired and ResultDescription startswith '[CSVROW]' | top 1 by TimeGenerated desc | project JobId_g); AzureDiagnostics | where Category == 'JobStreams' and StreamType_s == 'Output' and TimeGenerated > ago(6h) and ResultDescription startswith '[CSVROW]' and JobId_g == latest | where ResultDescription has '\"HardDelete\"' or ResultDescription startswith '[CSVROW] DisplayName' | order by TimeGenerated asc | project ResultDescription"
      }
      authentication = {
        type     = "ManagedServiceIdentity"
        audience = "https://api.loganalytics.io"
      }
    }
    runAfter = {}
  })
}

resource "azurerm_logic_app_action_custom" "pretty_email_delete_lines" {
  count = var.pretty_email_enabled ? 1 : 0

  name         = "select-delete-lines"
  logic_app_id = azurerm_logic_app_workflow.pretty_email[0].id

  body = jsonencode({
    type = "Select"
    inputs = {
      from   = "@coalesce(body('get-delete-rows')?['tables']?[0]?['rows'], json('[]'))"
      select = "@substring(item()[0], 9)"
    }
    runAfter = {
      "get-delete-rows" = ["Succeeded", "Failed"]
    }
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
        senderAddress = "${var.email_sender_username}@${azurerm_email_communication_service_domain.pretty[0].from_sender_domain}"
        recipients = {
          to = [for r in var.pretty_email_recipients : { address = r }]
        }
        content = {
          subject = "@{concat(if(${local.pe_is_dry}, '[Dry run] ', '[LIVE] '), coalesce(${local.pe_essentials}?['alertRule'], 'Device cleanup alert'), ' — ', string(coalesce(${local.pe_sum}?['ToDelete'], 0)), ' to delete, ', string(coalesce(${local.pe_sum}?['ToDisable'], 0)), ' to disable')}"
          html    = local.pe_html
        }
        attachments = "@if(${local.pe_is_jobfail}, json(concat('[{\"name\":\"job-streams.txt\",\"contentType\":\"text/plain\",\"contentInBase64\":\"', base64(join(coalesce(body('select-log-lines'), json('[]')), ${local.pe_nl})), '\"}]')), if(${local.pe_is_delete}, json(concat('[{\"name\":\"delete-candidates.csv\",\"contentType\":\"text/csv\",\"contentInBase64\":\"', base64(join(coalesce(body('select-delete-lines'), json('[]')), ${local.pe_nl})), '\"}]')), if(${local.pe_is_digest}, json(concat('[{\"name\":\"devices.csv\",\"contentType\":\"text/csv\",\"contentInBase64\":\"', base64(join(coalesce(body('select-csv-lines'), json('[]')), ${local.pe_nl})), '\"}]')), json('[]'))))"
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
      "select-log-lines"    = ["Succeeded", "Failed", "Skipped"]
      "select-csv-lines"    = ["Succeeded", "Failed", "Skipped"]
      "select-delete-lines" = ["Succeeded", "Failed", "Skipped"]
      "parse-run-summary"   = ["Succeeded", "Failed", "Skipped"]
    }
  })
}
