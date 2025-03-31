terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.93.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.6"
    }
    local = {
      source = "hashicorp/local"
      version = "~> 2.5.2"
    }
  }

  required_version = ">= 1.10.4"
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_availability_zones" "all" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023_x86" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

}

variable "public_ip_for_ssh" {
  description = "Your Public IP to allow SSH to EC2 (Format: 10.0.0.1/32)"
}

locals {
  vpc_cidr_block              = "10.0.0.0/16"
  key_pair_name               = "test_key_pair"
  cert_common_name            = "abdulhussain.test29mar2025.com"
  instance_sg_name            = "EC2 SG"
  instance_allowed_ports      = [[443, 443], [80, 80]]
  public_ip_for_ssh           = "210.4.104.150/32"
}

resource "tls_private_key" "test_ca_private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content  = tls_private_key.test_ca_private_key.private_key_pem
  filename = "${path.module}/${local.key_pair_name}.pem"
}

resource "tls_self_signed_cert" "test_ca_cert" {
  private_key_pem = tls_private_key.test_ca_private_key.private_key_pem

  is_ca_certificate = true

  subject {
    common_name = local.cert_common_name
  }

  validity_period_hours = 8760

  allowed_uses = [
    "digital_signature",
    "cert_signing",
    "crl_signing",
    "server_auth"
  ]
}

resource "aws_key_pair" "generated_key" {
  key_name   = local.key_pair_name
  public_key = tls_private_key.test_ca_private_key.public_key_openssh
}

resource "aws_vpc" "test_vpc" {
  cidr_block           = local.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "Test VPC"
  }
}

resource "aws_subnet" "public_subnets" {
  count = length(data.aws_availability_zones.all.names)

  vpc_id                  = aws_vpc.test_vpc.id
  cidr_block              = cidrsubnet(local.vpc_cidr_block, 4, count.index)
  availability_zone       = data.aws_availability_zones.all.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "test_public_subnet_${count.index + 1}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.test_vpc.id

  tags = {
    Name = "Test IGW"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.test_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Test public route table"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public_subnets)

  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_security_group" "instance_sg" {
  name        = local.instance_sg_name
  description = local.instance_sg_name
  vpc_id      = aws_vpc.test_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "instance_sg_allow_alb_rule" {
  count = length(local.instance_allowed_ports)

  security_group_id            = aws_security_group.instance_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port                    = local.instance_allowed_ports[count.index][0]
  ip_protocol                  = "tcp"
  to_port                      = local.instance_allowed_ports[count.index][1]
  description                  = "Allow ALB access to EC2"
}

resource "aws_vpc_security_group_ingress_rule" "instance_sg_allow_ssh_rule" {
  security_group_id = aws_security_group.instance_sg.id
  cidr_ipv4         = var.public_ip_for_ssh
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
  description       = "Allow SSH access to EC2"
}

resource "aws_instance" "test_instance" {
  ami                         = data.aws_ami.amazon_linux_2023_x86.id
  instance_type               = "t3.micro"
  associate_public_ip_address = true
  key_name                    = aws_key_pair.generated_key.key_name
  user_data                   = file("userdata.tpl")
  subnet_id                   = aws_subnet.public_subnets[0].id
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]

  provisioner "local-exec" {
    command = "chmod 400 ${path.module}/${local.key_pair_name}.pem"
  }
  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = tls_private_key.test_ca_private_key.private_key_pem
      host        = aws_instance.test_instance.public_ip
    }
    inline = [
      "echo '${tls_self_signed_cert.test_ca_cert.cert_pem}' > /home/ec2-user/test_ca_cert.pem",
      "echo '${tls_private_key.test_ca_private_key.private_key_pem}' > /home/ec2-user/test_ca_private_key.pem"
    ]
  }

  tags = {
    Name = "Test Instance"
  }
}