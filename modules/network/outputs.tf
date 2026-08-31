output "vpc_name" {
  description = "The name of the VPC"
  value       = try(module.vpc.name, local.name)
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "The primary CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "vpc_secondary_cidr_blocks" {
  description = "List of secondary CIDR blocks of the VPC"
  value       = module.vpc.vpc_secondary_cidr_blocks
}

output "default_security_group_id" {
  description = "The ID of the security group created by default on VPC creation"
  value       = module.vpc.default_security_group_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "private_subnets_cidr_blocks" {
  description = "List of CIDR blocks of private subnets"
  value       = module.vpc.private_subnets_cidr_blocks
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "intra_subnets" {
  description = "List of IDs of intra (control-plane) subnets"
  value       = module.vpc.intra_subnets
}

output "database_subnets" {
  description = "List of IDs of database subnets"
  value       = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  description = "Name of the database subnet group"
  value       = try(module.vpc.database_subnet_group_name, "")
}

output "private_route_table_ids" {
  description = "List of IDs of private route tables"
  value       = module.vpc.private_route_table_ids
}

output "tailscale_instance_id" {
  description = "The ID of the Tailscale relay instance (empty when disabled)"
  value       = try(aws_instance.tailscale[0].id, "")
}

output "tailscale_ip" {
  description = "The private IP address of the Tailscale relay (empty when disabled)"
  value       = try(aws_network_interface.tailscale[0].private_ips, [])
}

output "tailscale_security_group_id" {
  description = <<-EOT
    The dedicated Tailscale relay security group (empty when disabled). All
    tailnet traffic into the VPC is SNAT'd to the relay, so this is the source
    SG that in-VPC services (e.g. the private EKS API) should trust for admin
    access.
  EOT
  value       = try(aws_security_group.tailscale[0].id, "")
}
