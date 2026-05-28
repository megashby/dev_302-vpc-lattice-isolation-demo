resource "aws_cloudwatch_event_rule" "isolate_admin" {
  name = "isolate_admin"

  event_pattern = jsonencode({
    source = ["demo.isolate_admin"]
  })
}

resource "aws_cloudwatch_event_target" "incident_lambda" {
  rule = aws_cloudwatch_event_rule.isolate_admin.name

  arn = module.isolate_admin.lambda_function_arn
}