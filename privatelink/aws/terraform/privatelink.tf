terraform {
  required_version = ">= 0.12.17"
}

provider "aws" {
  region  = var.region
  version = "= 2.32.0"
}


variable "region" {
  description = "The AWS Region of the existing VPC"
  type = string
}

variable "vpc_id" {
  description = "The VPC ID to private link to Confluent Cloud"
  type = string
}

variable "privatelink_service_name" {
  description = "The Service Name from Confluent Cloud to Private Link with (provided by Confluent)"
  type = string
}

variable "bootstrap" {
  description = "The bootstrap server (ie: lkc-abcde-vwxyz.us-east-1.aws.glb.confluent.cloud:9092)"
  type = string
}

variable "subnets_to_privatelink" {
  description = "A map of Zone ID to Subnet ID (ie: {\"use1-az1\" = \"subnet-abcdef0123456789a\", ...})"
  type = map(string)
}

locals {
  hosted_zone = replace(regex("^[^.]+-([0-9a-zA-Z]+[.].*):[0-9]+$", var.bootstrap)[0], "glb.", "")
}


data "aws_vpc" "privatelink" {
  id = var.vpc_id
}

data "aws_availability_zone" "privatelink" {
  for_each = var.subnets_to_privatelink
  zone_id = each.key
}

resource "aws_security_group" "privatelink" {
  name = "ccloud-privatelink"
  description = "Confluent Cloud Private Link minimal security group"
  vpc_id = data.aws_vpc.privatelink.id

  ingress {
    # only necessary if redirect support from http/https is desired
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }

  ingress {
    from_port = 9092
    to_port = 9092
    protocol = "tcp"
    cidr_blocks = [data.aws_vpc.privatelink.cidr_block]
  }
}

resource "aws_vpc_endpoint" "privatelink" {
  vpc_id = data.aws_vpc.privatelink.id
  service_name = var.privatelink_service_name
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.privatelink.id,
  ]

  subnet_ids = [for zone, subnet_id in var.subnets_to_privatelink: subnet_id]
  private_dns_enabled = false
}

resource "aws_route53_zone" "privatelink" {
  name = local.hosted_zone

  vpc {
    vpc_id = data.aws_vpc.privatelink.id
  }
}

resource "aws_route53_record" "privatelink" {
  count = length(var.subnets_to_privatelink) == 1 ? 0 : 1
  zone_id = aws_route53_zone.privatelink.zone_id
  name = "*.${aws_route53_zone.privatelink.name}"
  type = "CNAME"
  ttl  = "60"
  records = [
    aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"]
  ]
}

locals {
  endpoint_prefix = split(".", aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"])[0]
}

resource "aws_route53_record" "privatelink-zonal" {
  for_each = var.subnets_to_privatelink

  zone_id = aws_route53_zone.privatelink.zone_id
  name = length(var.subnets_to_privatelink) == 1 ? "*" : "*.${each.key}"
  type = "CNAME"
  ttl  = "60"
  records = [
    format("%s-%s%s",
      local.endpoint_prefix,
      data.aws_availability_zone.privatelink[each.key].name,
      replace(aws_vpc_endpoint.privatelink.dns_entry[0]["dns_name"], local.endpoint_prefix, "")
    )
  ]
}
