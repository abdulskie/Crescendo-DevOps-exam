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
  }

  required_version = ">= 1.10.4"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
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

locals {
  vpc_cidr_block              = "10.0.0.0/16"
  selected_availability_zones = [data.aws_availability_zones.all.names[0], data.aws_availability_zones.all.names[1]]
  key_pair_name               = "test_key_pair"
  alb_sg_name                 = "ALB SG"
  instance_sg_name            = "EC2 SG"
  alb_name                    = "TestALB"
  tg_name                     = "TestTG"
  alb_allowed_ports           = [[443, 443], [80, 80], [8080, 8080]]
  instance_allowed_ports      = [[80, 80], [8080, 8080]]
}

resource "tls_private_key" "test_ca_private_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
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
  count = length(local.selected_availability_zones)

  vpc_id                  = aws_vpc.test_vpc.id
  cidr_block              = cidrsubnet(local.vpc_cidr_block, 4, count.index)
  availability_zone       = local.selected_availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "test_public_subnet_${count.index + 1}"
  }
}

resource "aws_subnet" "private_subnets" {
  count = length(local.selected_availability_zones)

  vpc_id            = aws_vpc.test_vpc.id
  cidr_block        = cidrsubnet(local.vpc_cidr_block, 4, (count.index + length(local.selected_availability_zones)))
  availability_zone = local.selected_availability_zones[count.index]

  tags = {
    Name = "test_private_subnet_${count.index + 1}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.test_vpc.id

  tags = {
    Name = "Test IGW"
  }
}

resource "aws_eip" "nat_gw_eip" {}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_gw_eip.id
  subnet_id     = aws_subnet.public_subnets[0].id

  tags = {
    Name = "Test NAT GW"
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

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.test_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_gw.id
  }
  tags = {
    Name = "Test private route table"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public_subnets)

  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private_subnets)

  subnet_id      = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_security_group" "alb_sg" {
  name        = local.alb_sg_name
  description = local.alb_sg_name
  vpc_id      = aws_vpc.test_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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

resource "aws_vpc_security_group_ingress_rule" "alb_sg_allow_http_and_https_rule" {
  count = length(local.alb_allowed_ports)

  security_group_id = aws_security_group.alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = local.alb_allowed_ports[count.index][0]
  ip_protocol       = "tcp"
  to_port           = local.alb_allowed_ports[count.index][1]
  description       = "Allow Web access to ALB"
}

resource "aws_vpc_security_group_ingress_rule" "instance_sg_allow_alb_rule" {
  count = length(local.instance_allowed_ports)

  security_group_id            = aws_security_group.instance_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id
  from_port                    = local.instance_allowed_ports[count.index][0]
  ip_protocol                  = "tcp"
  to_port                      = local.instance_allowed_ports[count.index][1]
  description                  = "Allow ALB access to EC2"
}

resource "aws_lb" "test_alb" {
  name               = local.alb_name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for subnet in aws_subnet.public_subnets : subnet.id]
  enable_http2       = false
}

resource "aws_lb_target_group" "test_tg_nginx" {
  name        = local.tg_name
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.test_vpc.id
}

resource "aws_lb_target_group" "test_tg_tomcat" {
  name        = "tomcat"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.test_vpc.id
}

resource "aws_lb_listener" "http_nginx" {
  load_balancer_arn = aws_lb.test_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test_tg_nginx.arn
  }

  tags = {
    Name = "HTTP Listener"
  }
}

resource "aws_lb_listener" "http_tomcat" {
  load_balancer_arn = aws_lb.test_alb.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test_tg_tomcat.arn
  }

  tags = {
    Name = "HTTP Listener"
  }
}

resource "aws_instance" "test_instance" {
  ami                         = data.aws_ami.amazon_linux_2023_x86.id
  instance_type               = "t2.micro"
  associate_public_ip_address = false
  key_name                    = aws_key_pair.generated_key.key_name
  user_data                   = file("userdata.tpl")
  subnet_id                   = aws_subnet.private_subnets[0].id
  vpc_security_group_ids      = [aws_security_group.instance_sg.id]

  tags = {
    Name = "Test Instance"
  }
}

resource "aws_lb_target_group_attachment" "instance_tg_attachment_nginx" {
  target_group_arn = aws_lb_target_group.test_tg_nginx.arn
  target_id        = aws_instance.test_instance.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "instance_tg_attachment_tomcat" {
  target_group_arn = aws_lb_target_group.test_tg_tomcat.arn
  target_id        = aws_instance.test_instance.id
  port             = 8080
}

resource "aws_cloudfront_distribution" "test_distribution" {
  origin {
    domain_name = aws_lb.test_alb.dns_name
    origin_id   = aws_lb.test_alb.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = aws_lb.test_alb.dns_name
    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    max_ttl                = 0
    default_ttl            = 0

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }
  }
  enabled = true
}

output "private_key" {
  value     = tls_private_key.test_ca_private_key.private_key_pem
  sensitive = true
}

output "nginx_domain_name" {
  value = "Access NGINX on ${aws_cloudfront_distribution.test_distribution.domain_name}"
}

output "tomcat_domain_name" {
  value = "Access Tomcat on ${aws_lb.test_alb.dns_name}:8080"
}