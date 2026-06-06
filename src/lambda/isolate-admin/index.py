import json
import os
import boto3

vpclattice = boto3.client("vpc-lattice")


def require(event, key):
    value = event.get(key)
    if not value:
        raise ValueError(f"Missing required field: {key}")
    return value


def lambda_handler(event, context):
    print("=== ROUTE ISOLATION START ===")
    print("event:", json.dumps(event))

    service_identifier = require(event, "serviceIdentifier")
    listener_identifier = require(event, "listenerIdentifier")
    rule_identifier = require(event, "ruleIdentifier")
    path = require(event, "path")

    maintenance_tg = os.environ["MAINTENANCE_TG_ID"]
    reason = event.get("reason", "route isolation requested")

    print("reason:", reason)
    print("path:", path)
    print("serviceIdentifier:", service_identifier)
    print("listenerIdentifier:", listener_identifier)
    print("ruleIdentifier:", rule_identifier)
    print("maintenanceTargetGroup:", maintenance_tg)

    response = vpclattice.update_rule(
        serviceIdentifier=service_identifier,
        listenerIdentifier=listener_identifier,
        ruleIdentifier=rule_identifier,
        action={
            "forward": {
                "targetGroups": [
                    {
                        "targetGroupIdentifier": maintenance_tg,
                        "weight": 100
                    }
                ]
            }
        }
    )

    print("response:", json.dumps(response, default=str))
    print("=== ROUTE ISOLATION COMPLETE ===")

    return {
        "status": "ok",
        "message": f"{path} switched to maintenance",
        "path": path,
        "serviceIdentifier": service_identifier,
        "listenerIdentifier": listener_identifier,
        "ruleIdentifier": rule_identifier,
        "ruleArn": response.get("arn")
    }