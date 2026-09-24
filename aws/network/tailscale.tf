# ------------------------------------------------------------------------------
# Tailscale relay (subnet router) -- optional
#
# Advertises the VPC's intra + private subnet routes into the tailnet so admins
# and CI can reach the private EKS API and other in-VPC endpoints. Hardened:
#   - lives in a PRIVATE subnet (egress via NAT), no public IP / inbound surface
#   - admin access via SSM Session Manager (no SSH key, no port 22)
#   - IMDSv2 required, encrypted gp3 root volume
#   - Ubuntu 24.04 LTS: pinned via var.ts_relay_ami, or Canonical's current
#     image from its SSM parameter when unpinned (see the variable for why an
#     unpinned relay gets rebuilt on Canonical's schedule, not yours)
#   - tagged so route approval flows through the tailnet ACL, not a user
#   - keeps itself current: tailscale-init.sh turns on Tailscale auto-updates,
#     so client releases (CVE fixes included) land without a rebuild
#
# All resources here are gated on var.enable_tailscale_subnet_router. Leave it
# off to bring your own private-access path (VPN, bastion, public EKS endpoint
# with CIDR allowlists, etc.).
# ------------------------------------------------------------------------------

data "aws_ssm_parameter" "ubuntu" {
  count = var.enable_tailscale_subnet_router && var.ts_relay_ami == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  # one() is null when the data source is not created, so this never indexes
  # an empty list -- whichever branch is taken.
  ts_relay_ami = var.ts_relay_ami != "" ? var.ts_relay_ami : one(data.aws_ssm_parameter.ubuntu[*].value)
}

# Everything that forces aws_instance.tailscale to be replaced, in one place, so
# the relay's pre-auth key can be re-minted whenever the instance is rebuilt.
resource "terraform_data" "relay_build" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  input = {
    ami           = local.ts_relay_ami
    instance_type = var.ts_relay_instance_type
  }
}

resource "aws_network_interface" "tailscale" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  subnet_id       = module.vpc.private_subnets[0]
  private_ips     = [cidrhost(module.vpc.private_subnets_cidr_blocks[0], 10)]
  security_groups = [aws_security_group.tailscale[0].id]

  # A subnet router forwards packets whose destination is not its own IP, so the
  # EC2 source/destination check must be disabled.
  source_dest_check = false

  tags = merge(local.tags, {
    Name = "tailscale-${local.environment}"
  })
}

# Persistent (non-ephemeral) pre-auth key so the relay keeps its node identity
# across reboots; tagged so the ACL autoApprovers approve its routes.
#
# Single-use, so it survives exactly one `tailscale up`: a replacement instance
# handed the same key fails to authenticate, and because tailscale-init.sh runs
# under `set -e` it dies there, leaving a relay that advertises no routes. The
# trigger mints a fresh key in the same apply that rebuilds the instance, so
# the new user_data always carries an unspent key.
resource "tailscale_tailnet_key" "relay" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  reusable      = false
  ephemeral     = false
  preauthorized = true
  tags          = [var.ts_relay_tag]

  lifecycle {
    replace_triggered_by = [terraform_data.relay_build[0]]
  }
}

data "aws_iam_policy_document" "tailscale_assume" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tailscale" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  name               = "tailscale-relay-${local.environment}"
  assume_role_policy = data.aws_iam_policy_document.tailscale_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "tailscale_ssm" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  role       = aws_iam_role.tailscale[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "tailscale" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  name = "tailscale-relay-${local.environment}"
  role = aws_iam_role.tailscale[0].name
  tags = local.tags
}

resource "aws_instance" "tailscale" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  instance_type        = var.ts_relay_instance_type
  ami                  = local.ts_relay_ami
  iam_instance_profile = aws_iam_instance_profile.tailscale[0].name

  primary_network_interface {
    network_interface_id = aws_network_interface.tailscale[0].id
  }

  # The ENI owns source_dest_check (false); ignore the instance-level default so
  # the two resources stop fighting over the same underlying setting.
  lifecycle {
    ignore_changes = [source_dest_check]

    precondition {
      condition     = var.ts_relay_client_id != "" && var.ts_relay_client_secret != ""
      error_message = "ts_relay_client_id and ts_relay_client_secret are required when enable_tailscale_subnet_router = true."
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Advertise intra + private subnet routes so the private EKS API is reachable.
  user_data = templatefile("${path.module}/tailscale-init.sh", {
    name               = "aws-${local.environment}"
    tailscale_auth_key = tailscale_tailnet_key.relay[0].key
    subnet_routes      = join(",", concat(module.vpc.intra_subnets_cidr_blocks, module.vpc.private_subnets_cidr_blocks))
  })

  tags = merge(local.tags, {
    Name = "tailscale-relay-${local.environment}"
  })

  # Its first boot downloads Tailscale through the NAT gateway: boot only once
  # the gateway and the private route tables are there, not just the subnet.
  depends_on = [module.vpc]
}

# ------------------------------------------------------------------------------
# Dedicated least-privilege security group. Egress is open (Tailscale
# coordination/DERP via NAT + forwarding to subnets). SGs are stateful, so
# forwarded return traffic needs no explicit ingress; only inbound WireGuard
# (for in-VPC direct peering) + ICMP are allowed.
# ------------------------------------------------------------------------------
resource "aws_security_group" "tailscale" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  name_prefix = "tailscale-relay-${local.environment}-"
  description = "Tailscale subnet router"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, {
    Name = "tailscale-relay-${local.environment}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tailscale_wireguard" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  security_group_id = aws_security_group.tailscale[0].id
  description       = "WireGuard (direct peering from within the VPC)"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  cidr_ipv4         = module.vpc.vpc_cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "tailscale_icmp" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  security_group_id = aws_security_group.tailscale[0].id
  description       = "ICMP from the VPC (diagnostics / tailscale ping)"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = module.vpc.vpc_cidr_block
}

resource "aws_vpc_security_group_egress_rule" "tailscale_all" {
  count = var.enable_tailscale_subnet_router ? 1 : 0

  security_group_id = aws_security_group.tailscale[0].id
  description       = "All egress (Tailscale control/DERP via NAT + subnet forwarding)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
