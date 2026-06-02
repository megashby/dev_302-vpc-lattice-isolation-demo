import json
import os
import boto3

vpclattice = boto3.client("vpc-lattice")


def lambda_handler(event, context):
    service_arn = os.environ["SERVICE_ARN"]

    blocked_arn = event.get("detail", {}).get("blockedArn")
    if not blocked_arn:
        raise ValueError("Missing detail.blockedArn")

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
                "Sid": "AllowOtherAuthorizedPrincipals",
                "Effect": "Allow",
                "Principal": {
                    "AWS": "*"
                },
                "Action": "vpc-lattice-svcs:Invoke",
                "Resource": "*"
            }
        ]
    }

    response = vpclattice.put_auth_policy(
        resourceIdentifier=service_arn,
        policy=json.dumps(policy, separators=(",", ":"))
    )

    print(json.dumps(response, default=str, indent=2))

    return {
        "statusCode": 200,
        "blockedArn": blocked_arn,
        "state": response.get("state")
    }