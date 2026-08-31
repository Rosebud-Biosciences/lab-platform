variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (drives cluster/VPC naming)"
  type        = string
  default     = "lab"
}

variable "jupyterhub_admin_users" {
  description = "Usernames granted JupyterHub admin rights"
  type        = list(string)
  default     = ["admin"]
}

variable "jupyterhub_allowed_users" {
  description = "Usernames allowed to log in (each sets their own password at first login). Empty lets ANY username claim an account — fine for a demo, set it for anything real."
  type        = list(string)
  default     = []
}

variable "jupyterhub_singleuser_image" {
  description = "Single-user server image. The default docker-stacks image includes pip, so the marimo postStart install works; a custom image should bake marimo in."
  type        = string
  default     = "quay.io/jupyter/minimal-notebook:latest"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "lab-platform"
    ManagedBy = "terraform"
  }
}
