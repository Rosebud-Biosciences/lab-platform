variable "name_prefix" {
  description = "Unique per-preview prefix (e.g. the PR/preview name). Prepended to each branch name so previews never collide."
  type        = string
}

variable "branch_sources" {
  description = <<-EOT
    Parent Neon branch identifiers to cut copy-on-write child branches from,
    keyed by an arbitrary logical name (e.g. "app", "dagster", "mlflow"). Each
    entry names the project, the parent branch, the role to read the password
    for, and the database. Typically populated from the production data-storage
    stack's remote-state outputs.
  EOT
  type = map(object({
    project_id       = string
    parent_branch_id = string
    role_name        = string
    db_name          = string
  }))
  default = {}
}

variable "autoscaling_min_cu" {
  description = "Minimum compute units for each branch endpoint"
  type        = number
  default     = 0.25
}

variable "autoscaling_max_cu" {
  description = "Maximum compute units for each branch endpoint"
  type        = number
  default     = 2
}

variable "suspend_timeout_seconds" {
  description = "Idle seconds before a branch endpoint auto-suspends"
  type        = number
  default     = 300
}
