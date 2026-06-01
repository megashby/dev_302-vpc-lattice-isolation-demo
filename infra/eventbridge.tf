resource "aws_cloudwatch_event_rule" "isolate_admin" {
  name = "${local.name}-isolate-admin"

  event_pattern = jsonencode({
    source = ["demo.isolate_admin"]
    detail-type = ["ShiftAdminRoute"]
  })
}

resource "aws_cloudwatch_event_target" "isolate_admin_lambda" {
  rule = aws_cloudwatch_event_rule.isolate_admin.name

  arn = module.isolate_admin.lambda_function_arn
}

resource "aws_cloudwatch_event_rule" "apply_auth" {
  name = "${local.name}-apply-auth"

  event_pattern = jsonencode({
    source      = ["demo.apply_auth"]
    detail-type = ["ApplyAuthPolicy"]
  })
}

resource "aws_cloudwatch_event_target" "apply_auth_lambda" {
  rule = aws_cloudwatch_event_rule.apply_auth.name
  arn  = module.apply_auth.lambda_function_arn
}

# resource "aws_lambda_permission" "allow_eventbridge_apply_auth" {
#   statement_id  = "AllowEventBridgeApplyAuth"
#   action        = "lambda:InvokeFunction"
#   function_name = module.isolate_admin_auth.lambda_function_name
#   principal     = "events.amazonaws.com"
#   source_arn    = aws_cloudwatch_event_rule.apply_auth.arn
# }

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
        Effect = "Allow"
        Action = [
          "states:StartExecution"
        ]
        Resource = aws_sfn_state_machine.isolation_workflow.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_start_isolation_sfn" {
  role       = aws_iam_role.eventbridge_start_isolation_sfn.name
  policy_arn = aws_iam_policy.eventbridge_start_isolation_sfn.arn
}

resource "aws_cloudwatch_event_rule" "isolation_workflow" {
  name = "${local.name}-isolation-workflow"

  event_pattern = jsonencode({
    source      = ["demo.isolation_workflow"]
    detail-type = ["IsolationWorkflow"]
  })
}

resource "aws_cloudwatch_event_target" "isolation_workflow_sfn" {
  rule     = aws_cloudwatch_event_rule.isolation_workflow.name
  arn      = aws_sfn_state_machine.isolation_workflow.arn
  role_arn = aws_iam_role.eventbridge_start_isolation_sfn.arn
}