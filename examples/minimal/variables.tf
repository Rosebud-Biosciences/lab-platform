variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (drives cluster/VPC naming)"
  type        = string
  default     = "dev"
}

variable "webapp_image" {
  description = "Container image (repository:tag) for the demo webapp"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "lab-platform"
    ManagedBy = "terraform"
  }
}
