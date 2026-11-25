output "cluster_name" {
  description = "The cluster the drill upgrades."
  value       = azurerm_kubernetes_cluster.lab.name
}

output "resource_group_name" {
  description = "Where the cluster lives."
  value       = data.azurerm_resource_group.lab.name
}

output "node_resource_group" {
  description = "The group AKS creates for nodes, disks, the load balancer and public IPs. Deleting the cluster deletes it; the teardown checks that it did."
  value       = azurerm_kubernetes_cluster.lab.node_resource_group
}
