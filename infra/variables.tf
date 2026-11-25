variable "resource_group_name" {
  description = <<-EOT
    The resource group the cluster lives in. It exists before the drill and
    outlives it, because the drill identity is Contributor on this group and
    nowhere else: it can build and delete a cluster here and cannot touch
    anything else in the subscription.
  EOT
  type        = string
  default     = "rg-aksupgrade-lab"
}

variable "prefix" {
  description = "Name prefix, so a stray resource is obviously from this lab."
  type        = string
  default     = "aksupgrade"
}

variable "kubernetes_version" {
  description = <<-EOT
    The control plane version, and the version every app node pool is upgraded
    to. Chosen at drill time from what the region offers rather than pinned
    here, because AKS retires patch versions and a pinned one stops deploying.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a full patch version such as 1.36.5."
  }
}

variable "app_pools" {
  description = <<-EOT
    The app node pools that exist right now, by name, with the Kubernetes
    version each runs. The drill creates one at the older version, measures it
    being upgraded to kubernetes_version, and removes it before the next pass,
    so at most one exists at a time.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.app_pools) : contains(["unprotected", "protected"], k)])
    error_message = "App pools are named after the pass that uses them: unprotected or protected."
  }

  validation {
    condition     = length(var.app_pools) <= 1
    error_message = "One app pool at a time. Two pools plus a surge node exceed the regional vCPU quota of 10."
  }
}

variable "vm_size" {
  description = <<-EOT
    Standard_D2als_v7, because it is the size this subscription has actually
    been able to place. Quota is not the test: older families have a quota of
    10 in every region checked and were refused for "Capacity Restrictions"
    anyway. The regional vCPU quota is also 10, which is why there is never
    more than one app pool: system node + two app nodes + one surge node is
    8 vCPUs.
  EOT
  type        = string
  default     = "Standard_D2als_v7"
}

variable "runner_ip" {
  description = "Public IP of the runner. The API server accepts connections from this address only."
  type        = string

  validation {
    condition     = can(cidrhost("${var.runner_ip}/32", 0))
    error_message = "runner_ip must be a single IPv4 address."
  }
}
