import json
import hashlib
import boto3
from botocore.exceptions import ClientError

vpclattice = boto3.client("vpc-lattice")

MANAGED_DENY_SID = "DenyCompromisedPrincipals"


def require(event, key):
    value = event.get(key)
    if not value:
        raise ValueError(f"Missing required field: {key}")
    return value


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def load_existing_policy(service_identifier):
    try:
        response = vpclattice.get_auth_policy(
            resourceIdentifier=service_identifier
        )

        policy_text = response.get("policy")
        if not policy_text:
            return {
                "Version": "2012-10-17",
                "Statement": []
            }

        return json.loads(policy_text)

    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")

        # No existing auth policy yet
        if code in ("ResourceNotFoundException", "NotFoundException"):
            return {
                "Version": "2012-10-17",
                "Statement": []
            }

        raise


def merge_block_statement(policy, blocked_arn):
    policy.setdefault("Version", "2012-10-17")

    statements = policy.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]

    managed_statement = None

    for statement in statements:
        if statement.get("Sid") == MANAGED_DENY_SID:
            managed_statement = statement
            break

    if managed_statement is None:
        managed_statement = {
            "Sid": MANAGED_DENY_SID,
            "Effect": "Deny",
            "Principal": {
                "AWS": []
            },
            "Action": "vpc-lattice-svcs:Invoke",
            "Resource": "*"
        }
        statements.insert(0, managed_statement)

    existing_principals = as_list(
        managed_statement
        .setdefault("Principal", {})
        .get("AWS")
    )

    if blocked_arn not in existing_principals:
        existing_principals.append(blocked_arn)

    managed_statement["Principal"]["AWS"] = (
        existing_principals[0]
        if len(existing_principals) == 1
        else existing_principals
    )

    policy["Statement"] = statements
    return policy


def lambda_handler(event, context):
    print("=== APPLY AUTH START ===")
    print("event:", json.dumps(event))

    blocked_arn = require(event, "blockedArn")
    service_identifier = require(event, "serviceIdentifier")

    policy = load_existing_policy(service_identifier)
    merged_policy = merge_block_statement(policy, blocked_arn)

    policy_json = json.dumps(merged_policy, separators=(",", ":"))

    print("serviceIdentifier:", service_identifier)
    print("blockedArn:", blocked_arn)
    print("mergedPolicy:", json.dumps(merged_policy, indent=2))

    response = vpclattice.put_auth_policy(
        resourceIdentifier=service_identifier,
        policy=policy_json
    )

    print("response:", json.dumps(response, default=str))
    print("=== APPLY AUTH COMPLETE ===")

    return {
        "statusCode": 200,
        "blockedArn": blocked_arn,
        "serviceIdentifier": service_identifier,
        "state": response.get("state"),
        "managedSid": MANAGED_DENY_SID
    }