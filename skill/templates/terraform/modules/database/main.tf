# database module — shared RDS Postgres cluster.
#
# The instance is long-lived; per-PR logical databases are created INSIDE
# it by the stack-side `per_pr_database` module (which uses the Postgres
# provider to `CREATE DATABASE pr_<N>` on apply and drop on destroy).
#
# Default sizing: db.t4g.micro, 20GB gp3, single-AZ, 7-day backups. Good
# for a small project's dev and staging; bump instance_class + multi_az
# for prod workloads.

# ─── Subnet group ───────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name_prefix = "${var.name_prefix}-"
  subnet_ids  = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-subnets"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Security group ─────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  description = "Postgres ingress from inside the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  # No egress needed; RDS only accepts inbound connections.

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Master credentials ─────────────────────────────────────────────────────

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?" # avoid shell-hostile chars in connection strings
}

# ─── Instance ───────────────────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-rds"

  engine                = "postgres"
  engine_version        = var.engine_version
  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"         # UTC
  maintenance_window      = "Mon:04:00-Mon:05:00" # UTC

  deletion_protection             = var.environment == "prod"
  skip_final_snapshot             = var.environment != "prod"
  final_snapshot_identifier       = var.environment == "prod" ? "${var.name_prefix}-final-snapshot-${formatdate("YYYYMMDD-hhmmss", timestamp())}" : null
  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true
  apply_immediately               = var.environment == "dev"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rds"
  })

  lifecycle {
    ignore_changes = [
      password,                  # Don't rotate via TF — manage externally if needed
      final_snapshot_identifier, # Timestamp always differs
    ]
  }
}

# ─── Secrets Manager ────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "master" {
  name_prefix             = "${var.name_prefix}-db-master-"
  description             = "Master credentials for ${var.name_prefix} RDS"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-master"
  })
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    engine            = "postgres"
    host              = aws_db_instance.main.address
    port              = aws_db_instance.main.port
    username          = aws_db_instance.main.username
    password          = random_password.master.result
    dbname            = aws_db_instance.main.db_name
    connection_string = "postgres://${aws_db_instance.main.username}:${random_password.master.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${aws_db_instance.main.db_name}?sslmode=require"
  })
}
