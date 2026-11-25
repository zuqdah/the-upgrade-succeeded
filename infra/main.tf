data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

resource "azurerm_kubernetes_cluster" "lab" {
  name                = "aks-${var.prefix}"
  location            = data.azurerm_resource_group.lab.location
  resource_group_name = data.azurerm_resource_group.lab.name
  dns_prefix          = var.prefix
  kubernetes_version  = var.kubernetes_version
  node_resource_group = "rg-${var.prefix}-nodes"

  # The free control plane. Standard adds an uptime SLA at $0.10 an hour,
  # which changes nothing about how a node pool upgrade drains its nodes.
  sku_tier = "Free"

  # Nothing upgrades this cluster except the drill. A node image rolled out by
  # a maintenance channel in the middle of a pass would drain nodes the
  # measurement does not know about.
  node_os_upgrade_channel = "None"

  # Entra ID for every caller, Azure RBAC for what they may do, and no local
  # admin certificate to leak. The drill identity holds "Azure Kubernetes
  # Service RBAC Cluster Admin" on the resource group, granted once at setup.
  local_account_disabled            = true
  role_based_access_control_enabled = true

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  api_server_access_profile {
    authorized_ip_ranges = ["${var.runner_ip}/32"]
  }

  # The system pool runs only what AKS itself needs, so the app pools are the
  # only nodes the upgrade drains while the probe is watching.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.vm_size
    node_count                   = 1
    orchestrator_version         = var.kubernetes_version
    only_critical_addons_enabled = true
    max_pods                     = 110
    os_disk_type                 = "Managed"
    os_disk_size_gb              = 32
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  # Node pools are declared here, not provisioned automatically. Node
  # auto-provisioning would choose and replace nodes itself, and the drill
  # needs to know exactly which nodes an upgrade drains.
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }
}

# One pool per pass. Both passes use identical pool settings -- same size, same
# node count, same surge, same drain timeout -- so the only thing that differs
# between them is the workload's own manifest.
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  for_each = var.app_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.lab.id
  mode                  = "User"
  vm_size               = var.vm_size
  node_count            = 2
  orchestrator_version  = each.value
  max_pods              = 110
  os_disk_type          = "Managed"
  os_disk_size_gb       = 32

  upgrade_settings {
    # One extra node during the upgrade, nodes drained one at a time. Stated
    # explicitly so the result does not depend on whatever the API's default
    # happens to be this year.
    max_surge = "1"

    # A disruption budget that can never be satisfied holds a drain open
    # forever. Fifteen minutes bounds that so the failure arrives during the
    # drill rather than after the runner gives up.
    drain_timeout_in_minutes      = 15
    node_soak_duration_in_minutes = 0
  }
}
