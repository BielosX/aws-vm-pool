resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
}

resource "aws_subnet" "public-subnet" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public-subnet-route-table" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public-subnet-route-table" {
  route_table_id = aws_route_table.public-subnet-route-table.id
  subnet_id = aws_subnet.public-subnet.id
}

resource "aws_security_group" "security-group" {
  vpc_id = aws_vpc.vpc.id
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    protocol = "tcp"
    from_port = 443
    to_port = 443
  }
  ingress {
    self = true
    protocol = "-1"
    from_port = 0
    to_port = 0
  }
  egress {
    self = true
    protocol = "-1"
    from_port = 0
    to_port = 0
  }
}

data "aws_ami" "amazon-linux-2023" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

data "aws_iam_policy_document" "assume-role-policy" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "role" {
  assume_role_policy = data.aws_iam_policy_document.assume-role-policy.json
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
}

resource "aws_iam_instance_profile" "profile" {
  role = aws_iam_role.role.id
}

locals {
  user-data = <<-EOM
  #!/bin/bash -xe
  yum update
  yum -y install jq
  yum -y install zsh
  yum -y install git
  yum -y install util-linux-user
  adduser ssm-user
  echo "ssm-user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/ssm-user
  chsh -s /bin/zsh ssm-user
  runuser -l ssm-user -c 'git clone https://github.com/ohmyzsh/ohmyzsh.git /home/ssm-user/.oh-my-zsh'
  runuser -l ssm-user -c 'cp /home/ssm-user/.oh-my-zsh/templates/zshrc.zsh-template /home/ssm-user/.zshrc'
  runuser -l ssm-user -c 'sed -i "s/ZSH_THEME=.*/ZSH_THEME=\"dallas\"/g" /home/ssm-user/.zshrc'
  EOM
}

resource "aws_launch_template" "template" {
  image_id = data.aws_ami.amazon-linux-2023.id
  instance_type = var.instance-type
  user_data = base64encode(local.user-data)
  iam_instance_profile {
    arn = aws_iam_instance_profile.profile.arn
  }
  network_interfaces {
    delete_on_termination = true
    subnet_id = aws_subnet.public-subnet.id
    security_groups = [aws_security_group.security-group.id]
  }
}

resource "aws_autoscaling_group" "asg" {
  max_size = var.number-of-instances
  min_size = var.number-of-instances
  launch_template {
    id = aws_launch_template.template.id
    version = aws_launch_template.template.latest_version
  }
}