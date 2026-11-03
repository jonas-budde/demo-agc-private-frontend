terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azapi   = { source = "Azure/azapi", version = "~> 2.0" }
    helm    = { source = "hashicorp/helm", version = "~> 2.17" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }
}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "germanywestcentral"
}
variable "prefix" {
  type    = string
  default = "agcpe"
}
variable "node_vm_size" {
  type    = string
  default = "Standard_D2as_v7"
}
variable "enable_private_frontend" {
  type    = bool
  default = true
}

locals {
  agc_api = "Microsoft.ServiceNetworking/trafficControllers"
  # Preview-era properties are not in every provider schema, so AzAPI schema validation is off.
  agc_api_version = "2026-03-01"
  tags            = { purpose = "demo", delete-after = "test" }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.0.0/24"]
}

resource "azurerm_subnet" "agc" {
  name                 = "snet-agc"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.1.0/24"]
  delegation {
    name = "agc"
    service_delegation {
      name    = "Microsoft.ServiceNetworking/trafficControllers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.2.0/24"]
}

resource "azurerm_kubernetes_cluster" "this" {
  name                      = "aks-${var.prefix}"
  resource_group_name       = azurerm_resource_group.this.name
  location                  = var.location
  dns_prefix                = "aks-${var.prefix}"
  sku_tier                  = "Free"
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  tags                      = local.tags

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }
}

# ALB controller identity (workload identity)
resource "azurerm_user_assigned_identity" "alb" {
  name                = "id-alb-controller"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "alb" {
  name                = "alb-controller"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.alb.id
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:azure-alb-system:alb-controller-sa"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "alb_config_manager" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}

resource "azurerm_role_assignment" "alb_subnet" {
  scope                = azurerm_subnet.agc.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}

resource "azurerm_role_assignment" "alb_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.alb.principal_id
}

resource "helm_release" "alb" {
  name             = "alb-controller"
  namespace        = "azure-alb-system"
  create_namespace = true
  repository       = "oci://mcr.microsoft.com/application-lb/charts"
  chart            = "alb-controller"
  version          = "1.12.4"

  set {
    name  = "albController.namespace"
    value = "azure-alb-system"
  }
  set {
    name  = "albController.podIdentity.clientID"
    value = azurerm_user_assigned_identity.alb.client_id
  }

  set {
    name  = "albController.privateFrontend"
    value = var.enable_private_frontend
  }

  depends_on = [azurerm_federated_identity_credential.alb, azurerm_role_assignment.alb_config_manager]
}

# Application Gateway for Containers (BYO)
resource "azapi_resource" "tc" {
  type                      = "${local.agc_api}@${local.agc_api_version}"
  name                      = "agc-${var.prefix}"
  parent_id                 = azurerm_resource_group.this.id
  location                  = var.location
  schema_validation_enabled = false
  tags                      = local.tags
  body                      = {}
  response_export_values    = ["properties"]
}

resource "azapi_resource" "assoc" {
  type                      = "${local.agc_api}/associations@${local.agc_api_version}"
  name                      = "assoc-agc"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  body = {
    properties = {
      associationType = "subnets"
      subnet          = { id = azurerm_subnet.agc.id }
    }
  }
}

resource "azapi_resource" "fe_public" {
  type                      = "${local.agc_api}/frontends@${local.agc_api_version}"
  name                      = "fe-public"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  response_export_values    = ["properties.fqdn"]
  body                      = local.fe_public_sec == null ? {} : { properties = { securityPolicyConfigurations = local.fe_public_sec } }
  depends_on                = [azapi_resource.assoc]
}

resource "azapi_resource" "fe_private" {
  count                     = var.enable_private_frontend ? 1 : 0
  type                      = "${local.agc_api}/frontends@${local.agc_api_version}"
  name                      = "fe-private"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  response_export_values    = ["properties"]
  body = {
    properties = merge({
      publicNetworkAccess = "Disabled"
      association         = { id = azapi_resource.assoc.id }
    }, local.fe_private_sec == null ? {} : { securityPolicyConfigurations = local.fe_private_sec })
  }
}

# Consumer side: private endpoint + private DNS
resource "azurerm_private_dns_zone" "agc" {
  count               = var.enable_private_frontend ? 1 : 0
  name                = "privatelink.alb.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "agc" {
  count                 = var.enable_private_frontend ? 1 : 0
  name                  = "vnet"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.agc[0].name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "agc" {
  count               = var.enable_private_frontend ? 1 : 0
  name                = "pe-agc-private-frontend"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "agc"
    private_connection_resource_id = azapi_resource.tc.id
    subresource_names              = ["fe-private"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.agc[0].id]
  }

  depends_on = [azapi_resource.fe_private]
}

output "resource_group" { value = azurerm_resource_group.this.name }
output "aks_name" { value = azurerm_kubernetes_cluster.this.name }
output "agc_id" { value = azapi_resource.tc.id }
output "public_frontend_fqdn" { value = azapi_resource.fe_public.output.properties.fqdn }
output "private_frontend" {
  value = var.enable_private_frontend ? azapi_resource.fe_private[0].output.properties : null
}
