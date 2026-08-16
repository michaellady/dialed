# NAT egress — fck-nat by default, AWS managed NAT Gateway on demand.
#
# fck-nat: self-hosted NAT on a t4g.nano EC2 instance in an ASG of size 1.
# ~$3-5/mo. Single instance, single AZ; fine for dev and most prod workloads.
# Switch to managed when you need multi-AZ HA or >5 Gbps throughput.

module "fck_nat" {
  count = var.nat_mode == "fck-nat" ? 1 : 0

  source  = "RaJiska/fck-nat/aws"
  version = "~> 1.4"

  name               = "${var.name_prefix}-nat"
  vpc_id             = aws_vpc.main.id
  subnet_id          = aws_subnet.public[0].id
  instance_type      = var.nat_instance_type
  use_spot_instances = false

  # Bound the NAT instance role to the project's permissions boundary. The bootstrap
  # tier gates the deploy role's iam:CreateRole on iam:PermissionsBoundary, so this
  # ${var.name_prefix}-nat role must carry the boundary or the shared-tier apply
  # AccessDenies. The fck-nat module (RaJiska/fck-nat/aws ~> 1.4, resolved 1.6.1) takes
  # permissions_boundary_arn and applies it to that role (its iam.tf). It expects null
  # for "no boundary", so coalesce our empty-string default to null.
  permissions_boundary_arn = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null

  tags = var.tags
}

# fck-nat's ENI lives in the private subnet's route target.
resource "aws_route" "private_nat_fck" {
  count = var.nat_mode == "fck-nat" ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.fck_nat[0].eni_id
}

# ─── Managed NAT Gateway (nat_mode=managed) ─────────────────────────────────

resource "aws_eip" "managed_nat" {
  count  = var.nat_mode == "managed" ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip"
  })
}

resource "aws_nat_gateway" "managed" {
  count = var.nat_mode == "managed" ? 1 : 0

  allocation_id = aws_eip.managed_nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-gw"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_nat_managed" {
  count = var.nat_mode == "managed" ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.managed[0].id
}
