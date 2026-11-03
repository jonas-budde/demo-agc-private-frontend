variable "enable_waf" {
  type    = bool
  default = false
}

# Gated by subscription feature flags (EnableAppGwForContainers*SecurityPolicy); fails with
# AppGwForContainersFrontendCannotConfigureWafSecurityPolicy when they are not approved.
variable "waf_on_frontend" {
  type    = bool
  default = false
}

# null = no IP access rules policy; [] = policy attached with zero rules (behavior to be tested)
variable "ip_rules" {
  type = list(object({
    name     = string
    priority = number
    action   = string
    prefixes = list(string)
  }))
  default = null
}

resource "azurerm_web_application_firewall_policy" "agc" {
  count               = var.enable_waf ? 1 : 0
  name                = "waf-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  policy_settings {
    enabled = true
    mode    = "Prevention"
  }

  custom_rules {
    name      = "BlockPath"
    priority  = 10
    rule_type = "MatchRule"
    action    = "Block"
    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator     = "Contains"
      match_values = ["/blocked"]
    }
  }

  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
  }
}

resource "azapi_resource" "sp_waf" {
  count                     = var.enable_waf ? 1 : 0
  type                      = "${local.agc_api}/securityPolicies@${local.agc_api_version}"
  name                      = "sp-waf"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  body = {
    properties = { wafPolicy = { id = azurerm_web_application_firewall_policy.agc[0].id } }
  }
}

resource "azapi_resource" "sp_ip" {
  count                     = var.ip_rules != null ? 1 : 0
  type                      = "${local.agc_api}/securityPolicies@${local.agc_api_version}"
  name                      = "sp-ip"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  body = {
    properties = {
      ipAccessRulesPolicy = {
        rules = [for r in var.ip_rules : {
          name                  = r.name
          priority              = r.priority
          action                = r.action
          sourceAddressPrefixes = r.prefixes
        }]
      }
    }
  }
}

locals {
  fe_public_sec = var.waf_on_frontend ? {
    wafSecurityPolicy = { id = azapi_resource.sp_waf[0].id }
  } : null

  fe_private_sec = (var.waf_on_frontend || var.ip_rules != null) ? merge(
    var.waf_on_frontend ? { wafSecurityPolicy = { id = azapi_resource.sp_waf[0].id } } : {},
    var.ip_rules != null ? { ipAccessRulesSecurityPolicy = { id = azapi_resource.sp_ip[0].id } } : {},
  ) : null
}
