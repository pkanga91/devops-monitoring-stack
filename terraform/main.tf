terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
}

variable "my_ip_cidr" {
  description = "Votre IP publique au format x.x.x.x/32"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Chemin de la cle publique SSH"
  type        = string
  default     = "~/.ssh/monitest.pub"
}

# 1. Paire de cles SSH (seule la cle publique est envoyee a AWS)
resource "aws_key_pair" "monitest" {
  key_name   = "monitest"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# 2. Security Group
resource "aws_security_group" "monitoring_sg" {
  name        = "monitoring-stack-sg"
  description = "Ports pour SSH, App, Grafana et Prometheus"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Image Ubuntu 24.04 la plus recente (Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 4. Instance EC2
resource "aws_instance" "monitoring_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.monitest.key_name
  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get upgrade -y
              apt-get install -y docker.io docker-compose-v2 git
              usermod -aG docker ubuntu
              EOF

  tags = {
    Name = "Monitoring-Server-DevOps"
  }
}

# 5. IP publique
output "server_public_ip" {
  value       = aws_instance.monitoring_server.public_ip
  description = "Adresse IP publique de l'instance de monitoring"
}
