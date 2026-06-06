import json

AUTH_FINDINGS = {
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration",
    "CredentialAccess:IAMUser/AnomalousBehavior",
}

ROUTE_FINDINGS = {
    "Runtime/BitcoinTool.B",
    "Runtime/CryptoCurrency.B!DNS",
}


def get_nested(obj, *keys):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def require(value, name):
    if not value:
        raise ValueError(f"Missing required field: {name}")
    return value


def get_service_identifier(detail):
    return (
        detail.get("serviceIdentifier")
        or detail.get("serviceId")
        or detail.get("serviceArn")
    )


def get_listener_identifier(detail):
    return (
        detail.get("listenerIdentifier")
        or detail.get("listenerId")
        or detail.get("listenerArn")
    )


def get_rule_identifier(detail):
    return (
        detail.get("ruleIdentifier")
        or detail.get("ruleId")
        or detail.get("ruleArn")
    )


def extract_iam_role_arn(event, detail):
    account_id = event.get("account") or detail.get("accountId")

    access_key = get_nested(detail, "resource", "accessKeyDetails") or {}
    user_type = access_key.get("userType")
    user_name = access_key.get("userName")

    if user_type == "AssumedRole" and user_name and account_id:
        return f"arn:aws:iam::{account_id}:role/{user_name}"

    return (
        get_nested(detail, "resource", "accessKeyDetails", "principalArn")
        or detail.get("blockedArn")
    )


def extract_runtime_context(detail):
    resource = detail.get("resource", {})

    ecs_cluster = resource.get("ecsClusterDetails") or {}
    container = resource.get("containerDetails") or {}

    return {
        "ecsClusterArn": ecs_cluster.get("arn"),
        "ecsClusterName": ecs_cluster.get("name"),
        "taskArn": container.get("taskArn") or ecs_cluster.get("taskArn"),
        "taskDefinitionArn": container.get("taskDefinitionArn") or ecs_cluster.get("taskDefinitionArn"),
        "containerName": container.get("containerName") or container.get("name"),
        "containerImage": container.get("image"),
        "containerImageId": container.get("imageId"),
    }


def lambda_handler(event, context):
    print("router event:", json.dumps(event))

    source = event.get("source")
    detail_type = event.get("detail-type")
    detail = event.get("detail", {}) or {}
    finding_type = detail.get("type")

    if source not in ["aws.guardduty", "demo.guardduty"]:
        raise ValueError(f"Unsupported source: {source}")

    if detail_type != "GuardDuty Finding":
        raise ValueError(f"Unsupported detail-type: {detail_type}")

    response = {
        "applyAuth": False,
        "shiftRoute": False,
        "findingType": finding_type,
        "reason": detail.get("reason", finding_type),
        "originalSource": source,
        "originalDetailType": detail_type,
    }

    if finding_type in AUTH_FINDINGS:
        blocked_arn = require(
            extract_iam_role_arn(event, detail),
            "blockedArn"
        )

        service_identifier = require(
            get_service_identifier(detail),
            "serviceIdentifier"
        )

        response.update({
            "applyAuth": True,
            "blockedArn": blocked_arn,
            "serviceIdentifier": service_identifier,
        })

    elif finding_type in ROUTE_FINDINGS:
        service_identifier = require(
            get_service_identifier(detail),
            "serviceIdentifier"
        )

        listener_identifier = require(
            get_listener_identifier(detail),
            "listenerIdentifier"
        )

        rule_identifier = require(
            get_rule_identifier(detail),
            "ruleIdentifier"
        )

        path = require(detail.get("path"), "path")

        response.update({
            "shiftRoute": True,
            "serviceIdentifier": service_identifier,
            "listenerIdentifier": listener_identifier,
            "ruleIdentifier": rule_identifier,
            "path": path,
        })

        response.update(extract_runtime_context(detail))

    else:
        print(f"No action mapped for finding type: {finding_type}")

    print("router response:", json.dumps(response))
    return response