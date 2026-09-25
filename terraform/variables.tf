variable "server_name" {
  description = "Display name of the Clouding server."
  type        = string
  default     = "valheim-server"
}

variable "hostname" {
  description = "DNS-compatible hostname assigned to the server."
  type        = string
  default     = "valheim-server"
}

variable "image_id" {
  description = "Clouding image ID for Ubuntu 24.04 LTS."
  type        = string

  validation {
    condition     = trimspace(var.image_id) != ""
    error_message = "image_id must not be empty."
  }
}

variable "flavor_id" {
  description = "Clouding flavor ID. Use a plan with at least 2 vCPU and 4 GB RAM for a small group."
  type        = string

  validation {
    condition     = trimspace(var.flavor_id) != ""
    error_message = "flavor_id must not be empty."
  }
}

variable "ssd_gb" {
  description = "Root volume size in GB."
  type        = number
  default     = 40

  validation {
    condition     = var.ssd_gb >= 20
    error_message = "ssd_gb must be at least 20 GB."
  }
}

variable "clouding_backup_enabled" {
  description = "Enable Clouding-managed VPS backups. This may add provider charges."
  type        = bool
  default     = false
}

variable "clouding_backup_frequency" {
  description = "Clouding-managed backup frequency when clouding_backup_enabled is true."
  type        = string
  default     = "OneDay"

  validation {
    condition = contains([
      "OneDay",
      "TwoDays",
      "ThreeDays",
      "FourDays",
      "FiveDays",
      "SixDays",
      "OneWeek",
    ], var.clouding_backup_frequency)
    error_message = "clouding_backup_frequency must be a supported Clouding backup frequency."
  }
}

variable "clouding_backup_slots" {
  description = "Number of Clouding-managed backups to retain."
  type        = number
  default     = 7

  validation {
    condition     = var.clouding_backup_slots >= 2 && var.clouding_backup_slots <= 30
    error_message = "clouding_backup_slots must be between 2 and 30."
  }
}

variable "ssh_key_id" {
  description = "Clouding SSH key ID used for administrative access."
  type        = string

  validation {
    condition     = trimspace(var.ssh_key_id) != ""
    error_message = "ssh_key_id must not be empty."
  }
}

variable "admin_cidr" {
  description = "IPv4 CIDR allowed to reach SSH, ideally your public IP with /32."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid IPv4 or IPv6 CIDR."
  }

  validation {
    condition     = trimspace(var.admin_cidr) != ""
    error_message = "admin_cidr must not be empty."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], trimspace(var.admin_cidr))
    error_message = "admin_cidr must not allow SSH from the entire internet."
  }
}
