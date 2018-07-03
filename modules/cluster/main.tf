# ------------------------------------------------------------------------------
# Resources
# ------------------------------------------------------------------------------
data "aws_region" "current" {}

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "main" {
  name = "${var.name_prefix}-cluster-instances"
}

data "template_file" "main" {
  template = "${file("${path.module}/cloud-config.yml")}"

  vars {
    stack_name       = "${var.name_prefix}-cluster-asg"
    region           = "${data.aws_region.current.name}"
    log_group_name   = "${aws_cloudwatch_log_group.main.name}"
    ecs_cluster_name = "${aws_ecs_cluster.main.name}"
    ecs_log_level    = "${var.ecs_log_level}"
  }
}

data "aws_iam_policy_document" "permissions" {
  # TODO: Restrict privileges to specific ECS services.
  statement {
    effect    = "Allow"
    resources = ["*"]

    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecs:CreateCluster",
      "ecs:DeregisterContainerInstance",
      "ecs:DiscoverPollEndpoint",
      "ecs:Poll",
      "ecs:RegisterContainerInstance",
      "ecs:StartTelemetrySession",
      "ecs:Submit*",
      "logs:CreateLogStream",
      "cloudwatch:PutMetricData",
      "ec2:DescribeTags",
      "logs:DescribeLogStreams",
      "logs:CreateLogGroup",
      "logs:PutLogEvents",
      "ssm:GetParameter",
    ]
  }

  statement {
    effect = "Allow"

    resources = [
      "${aws_cloudwatch_log_group.main.arn}",
    ]

    actions = [
      "logs:CreateLogStream",
      "logs:CreateLogGroup",
      "logs:PutLogEvents",
    ]
  }
}

module "asg" {
  source  = "telia-oss/asg/aws"
  version = "0.2.0"

  name_prefix          = "${var.name_prefix}-cluster"
  user_data            = "${data.template_file.main.rendered}"
  vpc_id               = "${var.vpc_id}"
  subnet_ids           = "${var.subnet_ids}"
  await_signal         = "true"
  pause_time           = "PT5M"
  health_check_type    = "EC2"
  instance_policy      = "${data.aws_iam_policy_document.permissions.json}"
  min_size             = "${var.min_size}"
  max_size             = "${var.max_size}"
  instance_type        = "${var.instance_type}"
  instance_ami         = "${var.instance_ami}"
  instance_key         = "${var.instance_key}"
  instance_volume_size = "${var.instance_volume_size}"

  ebs_block_devices = [{
    device_name           = "/dev/xvdcz"
    volume_type           = "gp2"
    volume_size           = "${var.docker_volume_size}"
    delete_on_termination = true
  }]

  tags = "${var.tags}"
}

resource "aws_security_group_rule" "ingress" {
  count                    = "${var.load_balancer_count}"
  security_group_id        = "${module.asg.security_group_id}"
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = "32768"
  to_port                  = "65535"
  source_security_group_id = "${element(var.load_balancers, count.index)}"
}

resource "random_integer" "alarm_random_postfix" {
  min = 11111
  max = 99999
}

resource "aws_cloudwatch_metric_alarm" "UtilizationDataStorageAlarm" {
  count               = "${var.allow_docker_drive_monitoring == true ? 1 : 0}"
  alarm_name          = "ecs-volume-usage-${random_integer.alarm_random_postfix.result}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "UtilizationDataStorage"
  namespace           = "System/Linux"
  period              = "60"
  statistic           = "Average"
  threshold           = "${var.docker_drive_monitoring_threshold}"
  alarm_description   = "Alarm when docker volume usage reach ${var.docker_drive_monitoring_threshold} percent"

  dimensions {
    AutoScalingGroupName = "${module.asg.id}"
  }
}
