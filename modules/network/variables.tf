variable "name" {
  description = "VPC name"
  type        = string
}

variable "environment" {
  description = "Environment name, used to name the Tailscale relay and (by default) derive the Karpenter/EKS discovery tag"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name tagged on private subnets for Karpenter subnet discovery. Empty derives \"eks-<environment>\"."
  type        = string
  default     = ""
}

variable "num_availability_zones" {
  description = "Number of availability zones to spread subnets across"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "The primary CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "secondary_vpc_cidr" {
  description = "Secondary CIDR block for the VPC (extra pod IP space for EKS/VPC-CNI)"
  type        = string
  default     = "100.64.0.0/16"
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway instead of one per AZ. Cheaper for dev/OSS defaults; set false for HA production."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Create interface/gateway VPC endpoints (S3, ECR, STS, logs, EC2, ELB) to keep AWS traffic off the NAT gateway"
  type        = bool
  default     = true
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# Tailscale subnet router (optional)
# ------------------------------------------------------------------------------

variable "enable_tailscale_subnet_router" {
  description = "Deploy a Tailscale subnet-router EC2 instance that advertises the private/intra subnet routes into your tailnet (the private-access path used for a private EKS API endpoint)"
  type        = bool
  default     = false
}

variable "ts_relay_client_id" {
  description = <<-EOT
    Tailscale OAuth client ID used to mint the relay's pre-auth key. Must be a
    client that OWNS tag:subnet-router (auth keys inherit only their client's
    tags). Required when enable_tailscale_subnet_router = true.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "ts_relay_client_secret" {
  description = "Tailscale subnet-router OAuth client secret. Required when enable_tailscale_subnet_router = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ts_relay_tag" {
  description = "Tailscale ACL tag applied to the relay's pre-auth key (its autoApprovers should cover the advertised routes)"
  type        = string
  default     = "tag:subnet-router"
}

variable "ts_relay_instance_type" {
  description = "EC2 instance type for the Tailscale relay"
  type        = string
  default     = "t3a.micro"
}
variable "ts_relay_ami" {
  description = <<-EOT
    AMI for the Tailscale relay. Empty resolves Canonical's current Ubuntu 24.04
    LTS image from its public SSM parameter at plan time -- convenient for a
    first apply, but `ami` forces replacement and Canonical republishes that
    parameter every few weeks, so an unpinned relay is rebuilt on whatever
    apply happens to follow, taking the tailnet's route into the private
    subnets with it for a few minutes. Pin it in anything long-lived.

    A rebuild is always safe to run (the relay's single-use pre-auth key is
    re-minted in the same apply; see terraform_data.relay_build) but never
    free, so bump the pin deliberately. The current image for a region:
      aws ssm get-parameter --region us-west-2 --output text \
        --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query Parameter.Value
  EOT
  type        = string
  default     = ""
}
