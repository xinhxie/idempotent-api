resource "aws_dynamodb_table" "financial_ledger" {
  name         = "idempotent-transactions-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "expiration_time"
    enabled        = true
  }

  tags = {
    Project     = "IdempotentAPI"
    Environment = "Dev"
  }
}

# Package/zip the Python code automatically
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/deployment-package.zip"
}

# Define the Trust Policy (Allows Lambda to assume the role)
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# Create role with policy defined above (so lambda is able to assume role)
resource "aws_iam_role" "lambda_execution_role" {
  name               = "idempotent_api_lambda_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Define the Least Privilege Database Policy
data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:ConditionCheckItem"
    ]
    # Restrict access exclusively to the table provisioned in this deployment
    resources = [aws_dynamodb_table.financial_ledger.arn]
  }
}

# Create policy with above acess (dynamodb_access)
resource "aws_iam_policy" "lambda_dynamodb_policy" {
  name   = "idempotent_api_dynamodb_policy"
  policy = data.aws_iam_policy_document.dynamodb_access.json
}

# Attach the database policy to lambda_execution_role so it can perform PutItem, UpdateItem, and ConditionCheckItem on the financial_ledger table
resource "aws_iam_role_policy_attachment" "attach_dynamodb_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

# Attach basic execution role (Allows Lambda to write to CloudWatch logs for debugging)
resource "aws_iam_role_policy_attachment" "attach_logging_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Provision the Lambda Function
resource "aws_lambda_function" "transaction_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ProcessFinancialTransaction"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 5

  # Ensure the Lambda waits for the IAM role to propagate
  depends_on = [
    aws_iam_role_policy_attachment.attach_logging_policy,
    aws_iam_role_policy_attachment.attach_dynamodb_policy
  ]
}

# Create the REST API
resource "aws_api_gateway_rest_api" "transaction_api" {
  name        = "IdempotentTransactionAPI"
  description = "API for processing financial transactions securely"
}

# Create the Resource path (e.g., /transactions)
resource "aws_api_gateway_resource" "transaction_resource" {
  rest_api_id = aws_api_gateway_rest_api.transaction_api.id
  parent_id   = aws_api_gateway_rest_api.transaction_api.root_resource_id
  path_part   = "transactions"
}

# Create the HTTP Method (POST)
resource "aws_api_gateway_method" "transaction_post" {
  rest_api_id      = aws_api_gateway_rest_api.transaction_api.id
  resource_id      = aws_api_gateway_resource.transaction_resource.id
  http_method      = "POST"
  authorization    = "NONE" # We will keep it open for this public portfolio project
  api_key_required = true
}

# Integrate API Gateway directly with Lambda
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.transaction_api.id
  resource_id             = aws_api_gateway_resource.transaction_resource.id
  http_method             = aws_api_gateway_method.transaction_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.transaction_processor.invoke_arn
}

# Grant API Gateway permission to invoke the Lambda function
resource "aws_lambda_permission" "apigw_lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transaction_processor.function_name
  principal     = "apigateway.amazonaws.com"

  # Restrict invocation exclusively to this specific API Gateway
  source_arn = "${aws_api_gateway_rest_api.transaction_api.execution_arn}/*/*"
}

# deploy api gateway deployment
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.transaction_api.id

  depends_on = [
    aws_api_gateway_integration.lambda_integration
  ]
}

resource "aws_api_gateway_stage" "prod_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.transaction_api.id
  stage_name    = "prod"
}

# gateway api key
resource "aws_api_gateway_api_key" "recruiter_key" {
  name    = "PortfolioAccessKey"
  enabled = true
}

# set up limits for api_gateway
resource "aws_api_gateway_usage_plan" "portfolio_usage_plan" {
  name        = "RecruiterUsagePlan"
  description = "Limits traffic to prevent AWS Free Tier exhaustion"

  api_stages {
    api_id = aws_api_gateway_rest_api.transaction_api.id
    stage  = aws_api_gateway_stage.prod_stage.stage_name
  }

  quota_settings {
    limit  = 100
    period = "MONTH"
  }

  throttle_settings {
    burst_limit = 2
    rate_limit  = 2
  }
}

# Bind the Key to the Usage Plan
resource "aws_api_gateway_usage_plan_key" "bind_key" {
  key_id        = aws_api_gateway_api_key.recruiter_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.portfolio_usage_plan.id
}