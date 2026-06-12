resource "aws_cloudwatch_event_rule" "isolation_workflow" {
  name = "${local.name}-isolation-workflow"

  event_pattern = jsonencode({
    source = [
      "demo.apply_auth",
      "demo.isolate_endpoint",
      "demo.isolation_workflow",
      "demo.guardduty",
      "aws.guardduty",
      "aws.securityhub"
    ]
  })
}

resource "aws_iam_role" "eventbridge_start_isolation_sfn" {
  name = "${local.name}-eventbridge-start-isolation-sfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "eventbridge_start_isolation_sfn" {
  name = "${local.name}-eventbridge-start-isolation-sfn"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.isolation_workflow.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_start_isolation_sfn" {
  role       = aws_iam_role.eventbridge_start_isolation_sfn.name
  policy_arn = aws_iam_policy.eventbridge_start_isolation_sfn.arn
}

resource "aws_cloudwatch_event_target" "isolation_workflow_sfn" {
  rule     = aws_cloudwatch_event_rule.isolation_workflow.name
  arn      = aws_sfn_state_machine.isolation_workflow.arn
  role_arn = aws_iam_role.eventbridge_start_isolation_sfn.arn
}