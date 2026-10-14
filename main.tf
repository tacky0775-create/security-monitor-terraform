terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

resource "aws_vpc" "security_monitor_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "security-monitor-vpc"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.security_monitor_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "security-monitor-public-subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.security_monitor_vpc.id
  tags = {
    Name = "security-monitor-igw"

  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.security_monitor_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "security-monitor-public-rt"
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "security_monitor_sg" {
  name        = "security-monitor-sg"
  description = "Security monitor security group"
  vpc_id      = aws_vpc.security_monitor_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "security-monitor-sg"
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "security-monitor-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "security-monitor-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_logs" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "security-monitor-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_security_group" "ec2_sg" {
  name        = "security-monitor-ec2-sg"
  description = "Security group for security monitor EC2"
  vpc_id      = aws_vpc.security_monitor_vpc.id

  /*
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"

    cidr_blocks = ["0.0.0.0/0"]
  }
*/

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "security-monitor-ec2-sg"
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "security_monitor_ec2" {
  ami = "ami-0990bd2af79bd53a7"

  instance_type = "t3.micro"

  subnet_id = aws_subnet.public_subnet.id

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  associate_public_ip_address = true

  tags = {
    Name = "security-monitor-ec2"
  }

  lifecycle {
    ignore_changes = [
      associate_public_ip_address,
      ami,
    ]
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_cloudwatch_log_metric_filter" "ssh_failed_password" {
  name           = "SSHFailedPasswordFilter"
  log_group_name = "/security-monitor/linux/sshd"
  pattern        = "{ $.body.MESSAGE = \"*Failed password*\" }"

  metric_transformation {
    name          = "SSHFailedPasswordCount"
    namespace     = "SecurityMonitor/Linux"
    value         = "1"
    default_value = 0
    unit          = "None"
  }
}

resource "aws_cloudwatch_metric_alarm" "ssh_failed_password" {
  alarm_name          = "SSHFailedPasswordAlarm"
  alarm_description   = "Detect repeated SSH failed password attempts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "SSHFailedPasswordCount"
  namespace           = "SecurityMonitor/Linux"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = [
    aws_sns_topic.send_to_email_topic.arn
  ]
}

# SNS Topicの作成
resource "aws_sns_topic" "send_to_email_topic" {
  name = "send_to_email_topic"
}

# SNSメールサブスクリプション
resource "aws_sns_topic_subscription" "send_to_email_subscription" {
  topic_arn = aws_sns_topic.send_to_email_topic.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# SNS Topic ARNを出力
output "sns_topic_arn" {
  value = aws_sns_topic.send_to_email_topic.arn
}

# notification_email定義
variable "notification_email" {
  description = "Email address for security alerts"
  type        = string
}
