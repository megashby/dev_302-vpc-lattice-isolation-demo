import boto3
import os

vpclattice = boto3.client("vpc-lattice")


def lambda_handler(event, context):

    listener_id = os.environ["LISTENER_ID"]
    service_id = os.environ["SERVICE_ID"]
    rule_id = os.environ["RULE_ID"]
    maintenance_tg = os.environ["MAINTENANCE_TG_ARN"]

    response = vpclattice.update_rule(
        listenerIdentifier=listener_id,
        serviceIdentifier=service_id,
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

    return response