terraform {
  required_version = ">= 1.5.0"

  required_providers {
    clouding = {
      source  = "renemontilva/clouding"
      version = "~> 1.0"
    }
  }
}

provider "clouding" {}

