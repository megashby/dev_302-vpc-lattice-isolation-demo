 resource "aws_iam_role" "isolation_sfn" {
  name = "${local.name}-isolation-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "isolation_sfn" {
  name = "${local.name}-isolation-sfn-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          module.apply_auth.lambda_function_arn,
          module.isolate_admin.lambda_function_arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "isolation_sfn" {
  role       = aws_iam_role.isolation_sfn.name
  policy_arn = aws_iam_policy.isolation_sfn.arn
}

resource "aws_sfn_state_machine" "isolation_workflow" {
  name     = "${local.name}-admin-isolation-workflow"
  role_arn = aws_iam_role.isolation_sfn.arn

  definition = jsonencode({
    Comment = "Conditional VPC Lattice admin isolation workflow"
    StartAt = "ShouldApplyAuth"

    States = {
      ShouldApplyAuth = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.applyAuth"
            BooleanEquals = true
            Next          = "ApplyAuthPolicy"
          }
        ]
        Default = "ShouldShiftRoute"
      }

      ApplyAuthPolicy = {
        Type     = "Task"
        Resource = module.apply_auth.lambda_function_arn
        Next     = "ShouldShiftRoute"
      }

      ShouldShiftRoute = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.shiftRoute"
            BooleanEquals = true
            Next          = "ShiftAdminRoute"
          }
        ]
        Default = "Done"
      }

      ShiftAdminRoute = {
        Type     = "Task"
        Resource = module.isolate_admin.lambda_function_arn
        Next     = "Done"
      }

      Done = {
        Type = "Succeed"
      }
    }
  })
}