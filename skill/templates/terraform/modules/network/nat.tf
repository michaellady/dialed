# NAT egress — fck-nat by default, AWS managed NAT Gateway on demand.
#
# fck-nat: self-hosted NAT on a t4g.nano EC2 instance in an ASG of size 1.
# ~$3-5/mo. Single instance, single AZ; fine for dev and most prod workloads.
# Switch to managed when you need multi-AZ HA or >5 Gbps throughput.

module "fck_nat" {
  count = var.nat_mode == "fck-nat" ? 1 : 0

  # `~> 1.4` auto-accepts patch releases, and a fck-nat 1.4.x patch RAISED its own
  # required_version to `~> 1.9` — which becomes the effective Terraform floor for the
  # whole stack at `terraform init`. If you ever see "Unsupported Terraform Core version"
  # in a shared/stack apply, it is this module: bump dialed-setup's terraform_version
  # default to satisfy it (see skill/templates/actions/dialed-setup/action.yml).
  source  = "RaJiska/fck-nat/aws"
  version = "~> 1.4"

  name               = "${var.name_prefix}-nat"
  vpc_id             = aws_vpc.main.id
  subnet_id          = aws_subnet.public[0].id
  instance_type      = var.nat_instance_type
  use_spot_instances = false

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
