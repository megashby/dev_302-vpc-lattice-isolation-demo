import boto3
import os

vpclattice = boto3.client("vpc-lattice")

def lambda_handler(event, context):

    listener_id = os.environ["LISTENER_ID"]
    service_id = os.environ["SERVICE_ID"]
    rule_id = os.environ["RULE_ID"]
    maintenance_tg = os.environ["MAINTENANCE_TG_ID"]  # IMPORTANT: ID, not ARN

    print("=== ISOLATION START ===")
    print("Switching /admin route to MAINTENANCE target group")

    try:
        response = vpclattice.update_rule(
            serviceIdentifier=service_id,
            listenerIdentifier=listener_id,
            ruleIdentifier=rule_id,
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

        print("Rule update successful")
        print(response)

        print("=== ISOLATION COMPLETE ===")

        return {
            "status": "ok",
            "message": "Admin endpoint switched to maintenance",
            "ruleArn": response.get("arn")
        }

    except Exception as e:
        print("FATAL ERROR switching to maintenance")
        print(str(e))
        raise