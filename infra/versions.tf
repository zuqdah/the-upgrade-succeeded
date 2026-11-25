terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }
}

provider "azurerm" {
  # Microsoft.ContainerService was registered once, by hand, when this lab was
  # set up. A lab should not be quietly changing subscription-wide state, and
  # the drill identity has no permission to do it anyway.
  resource_provider_registrations = "none"

  features {}
}
