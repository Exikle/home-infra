terraform {
  required_version = ">= 1.12.0"

  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "1.9.3"
    }
  }

  backend "local" {}
}
