terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100, < 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47"
    }
  }

  # Local state by default (gitignored). Move to a remote backend if this
  # project outgrows single-operator use.
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}
