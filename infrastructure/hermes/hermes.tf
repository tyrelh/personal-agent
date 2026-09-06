# --- Secret -------------------------------------------------------------
# Created by hand outside terraform (see README) so no key material ever lands in
# state. Terraform only reads its ARN to scope the instance role.
data "aws_secretsmanager_secret" "hermes" {
  name = "hermes"
}

# --- IAM ----------------------------------------------------------------
resource "aws_iam_role" "hermes" {
  name = "hermes-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.hermes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secret" {
  name = "read-hermes-secret"
  role = aws_iam_role.hermes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = data.aws_secretsmanager_secret.hermes.arn
    }]
  })
}

resource "aws_iam_instance_profile" "hermes" {
  name = "hermes-instance"
  role = aws_iam_role.hermes.name
}

# --- Network ------------------------------------------------------------
# Zero ingress rules, deliberately. SGs are stateful default-deny, so a public IP
# with no ingress rule is unreachable. Any ingress rule appearing here is drift.
resource "aws_security_group" "hermes" {
  name        = "hermes"
  description = "Hermes agent: egress only, no inbound"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.hermes.id
  description       = "LLM APIs, Slack socket mode, SSM, Tailscale DERP fallback"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "tailscale" {
  security_group_id = aws_security_group.hermes.id
  description       = "Tailscale direct WireGuard"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
}

# Without STUN, Tailscale never gets a direct path and falls back to relaying
# every packet over DERP on 443. It works, it's just slow.
resource "aws_vpc_security_group_egress_rule" "stun" {
  security_group_id = aws_security_group.hermes.id
  description       = "Tailscale NAT traversal (STUN)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478
}

# Not in the plan's "443 + 41641" list, but the box does not boot usefully without
# them: Ubuntu's arm64 apt mirrors are plain HTTP, and DNS goes to the VPC resolver.
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.hermes.id
  description       = "apt / unattended-upgrades (ports.ubuntu.com is http)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  security_group_id = aws_security_group.hermes.id
  description       = "DNS to the VPC resolver"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

# --- Instance -----------------------------------------------------------
resource "aws_instance" "hermes" {
  ami           = data.aws_ssm_parameter.ubuntu_2404_arm64.value
  instance_type = "t4g.medium"

  # Deterministic pick so a reordered subnet list doesn't replace the instance.
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.hermes.id]
  iam_instance_profile   = aws_iam_instance_profile.hermes.name

  # Ephemeral public IP, no EIP. Nothing should ever point at this box.
  associate_public_ip_address = true

  # Changing this does NOT replace the instance (user_data_replace_on_change
  # defaults false) — cloud-init only runs it on first boot. Rebuild deliberately.
  # install_hermes.sh goes through file(), not templatefile() — README Phase 2 says why.
  user_data = templatefile("${path.module}/user_data.sh", {
    secret_id      = data.aws_secretsmanager_secret.hermes.name
    region         = data.aws_region.current.region
    install_hermes = file("${path.module}/install_hermes.sh")
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  # hop_limit 1 stops Docker containers from reaching IMDS and stealing the role.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    # ~/.hermes lives here. Survives an accidental terminate; orphan volume is the
    # deliberate trade. Delete by hand if you really mean it.
    delete_on_termination = false
    tags                  = { Name = "hermes-root" }
  }

  tags = { Name = "hermes" }

  # Canonical publishes new 24.04 images constantly; without this a routine apply
  # would replace the running agent. Bump deliberately by tainting the instance.
  lifecycle {
    ignore_changes = [ami]
  }
}

output "instance_id" {
  value = aws_instance.hermes.id
}

output "public_ip" {
  value = aws_instance.hermes.public_ip
}

output "secret_arn" {
  value = data.aws_secretsmanager_secret.hermes.arn
}
