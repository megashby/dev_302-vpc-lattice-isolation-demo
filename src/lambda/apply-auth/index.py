import json
import boto3

vpclattice = boto3.client("vpc-lattice")


def require(event, key):
    value = event.get(key)
    if not value:
        raise ValueError(f"Missing required field: {key}")
    return value


def lambda_handler(event, context):
    print("=== APPLY AUTH START ===")
    print("event:", json.dumps(event))

    blocked_arn = require(event, "blockedArn")
    service_identifier = require(event, "serviceIdentifier")

    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "DenyCompromisedPrincipal",
                "Effect": "Deny",
                "Principal": {
                    "AWS": blocked_arn
                },
                "Action": "vpc-lattice-svcs:Invoke",
                "Resource": "*"
            },
            {
                "Sid": "AllowAllOtherPrincipals",
                "Effect": "Allow",
                "Principal": {
                    "AWS": "*"
                },
                "Action": "vpc-lattice-svcs:Invoke",
                "Resource": "*"
            }
        ]
    }

    print("serviceIdentifier:", service_identifier)
    print("blockedArn:", blocked_arn)
    print("policy:", json.dumps(policy, indent=2))

    response = vpclattice.put_auth_policy(
        resourceIdentifier=service_identifier,
        policy=json.dumps(policy)
    )

    print("response:", json.dumps(response, default=str))
    print("=== APPLY AUTH COMPLETE ===")

    return {
        "statusCode": 200,
        "blockedArn": blocked_arn,
        "serviceIdentifier": service_identifier,
        "state": response.get("state")
    }