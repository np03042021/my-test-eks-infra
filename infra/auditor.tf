############################################
# Daily security auditor Lambda (Python). Cost: 1 invocation/day, well inside the free tier.
############################################
locals {
  auditor_name = "${local.name}-security-auditor"
}

# Only handler.py is packaged; tests and dev lockfile are not shipped.
# boto3 comes from the Lambda runtime. Prod: vendor a pinned boto3 (layer) to avoid runtime drift.
data "archive_file" "auditor" {
  type        = "zip"
  source_file = "${path.module}/auditor/handler.py"
  output_path = "${path.module}/build/auditor.zip"
}

# Created by Terraform (not by Lambda) so retention is enforced and the function
# needs no logs:CreateLogGroup permission.
resource "aws_cloudwatch_log_group" "auditor" {
  #checkov:skip=CKV_AWS_158:AWS-owned key encryption is the default; a CMK costs $1/month. Prod: CMK.
  #checkov:skip=CKV_AWS_338:DEMO ONLY 7-day retention to keep cost near zero. Prod: >= 1 year or ship to a SIEM.
  name              = "/aws/lambda/${local.auditor_name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "auditor_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "auditor" {
  name               = "${local.auditor_name}-role"
  assume_role_policy = data.aws_iam_policy_document.auditor_trust.json
}

# Read-only, exactly the five API calls the auditor makes, plus writing to its own log group.
data "aws_iam_policy_document" "auditor" {
  statement {
    sid       = "WriteOwnLogsOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.auditor.arn}:*"]
  }
  statement {
    # Describe/List actions below do not support resource-level permissions; AWS requires "*".
    sid       = "DescribeWithoutResourceScope"
    actions   = ["ec2:DescribeSecurityGroups", "eks:ListClusters"]
    resources = ["*"]
  }
  statement {
    sid       = "IamUsersAndKeys"
    actions   = ["iam:ListUsers", "iam:ListAccessKeys"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:user/*"]
  }
  statement {
    sid       = "DescribeClustersInRegion"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/*"]
  }
}

resource "aws_iam_role_policy" "auditor" {
  name   = "auditor-read-only"
  role   = aws_iam_role.auditor.id
  policy = data.aws_iam_policy_document.auditor.json
}

resource "aws_lambda_function" "auditor" {
  #checkov:skip=CKV_AWS_116:Scheduled, idempotent audit; a missed run is caught the next day, so no DLQ.
  #checkov:skip=CKV_AWS_117:Not in a VPC: there is no NAT, and it only calls AWS APIs. Prod: VPC + interface endpoints.
  #checkov:skip=CKV_AWS_115:Reserved concurrency can fail on new accounts (limit 10). Schedule fires once a day.
  #checkov:skip=CKV_AWS_50:X-Ray tracing adds IAM permissions and cost with no value for a 1/day job.
  #checkov:skip=CKV_AWS_272:Code signing is on the roadmap (Signer profile + CI signing step).
  function_name    = local.auditor_name
  description      = "Daily audit: open security groups, stale IAM keys, public EKS endpoints"
  role             = aws_iam_role.auditor.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  architectures    = ["arm64"] # Graviton: ~20% cheaper per GB-second
  filename         = data.archive_file.auditor.output_path
  source_code_hash = data.archive_file.auditor.output_base64sha256
  timeout          = 60
  memory_size      = 128

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.auditor.name
  }

  depends_on = [aws_iam_role_policy.auditor, aws_cloudwatch_log_group.auditor]
}

resource "aws_cloudwatch_event_rule" "auditor_daily" {
  name                = "${local.auditor_name}-daily"
  description         = "Run the security auditor once a day"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "auditor" {
  rule = aws_cloudwatch_event_rule.auditor_daily.name
  arn  = aws_lambda_function.auditor.arn
}

# Only this EventBridge rule may invoke the function.
resource "aws_lambda_permission" "auditor_events" {
  statement_id  = "AllowDailyRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auditor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.auditor_daily.arn
}
