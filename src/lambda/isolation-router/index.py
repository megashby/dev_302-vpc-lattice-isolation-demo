import json
import os

DEFAULT_ADMIN_RULE_ID = os.environ.get("DEFAULT_ADMIN_RULE_ID", "")
DEFAULT_ADMIN_PATH = os.environ.get("DEFAULT_ADMIN_PATH", "/admin/")

AUTH_FINDINGS = {
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration",
    "CredentialAccess:IAMUser/AnomalousBehavior",
}

ROUTE_FINDINGS = {
    "Runtime/BitcoinTool.B",
    "Runtime/CryptoCurrency.B!DNS",
    "CryptoCurrency:Runtime/BitcoinTool.B",
    "CryptoCurrency:Runtime/BitcoinTool.B!DNS",
    "Backdoor:Runtime/C&CActivity.B!DNS",
}


def get_nested(obj, *keys):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def extract_iam_role_arn(event, detail):
    account_id = event.get("account") or detail.get("accountId")

    access_key = get_nested(detail, "resource", "accessKeyDetails") or {}
    user_type = access_key.get("userType")
    user_name = access_key.get("userName")

    if user_type == "AssumedRole" and user_name and account_id:
        return f"arn:aws:iam::{account_id}:role/{user_name}"

    # Optional escape hatch for mock/demo events
    return (
        get_nested(detail, "resource", "accessKeyDetails", "principalArn")
        or detail.get("blockedArn")
    )


def extract_runtime_context(detail):
    resource = detail.get("resource", {})

    # Shapes vary across runtime resources, so keep this defensive.
    ecs_cluster = (
        resource.get("ecsClusterDetails")
        or resource.get("ecsCluster")
        or {}
    )

    container = (
        resource.get("containerDetails")
        or resource.get("container")
        or {}
    )

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

    response = {
        "applyAuth": False,
        "shiftRoute": False,
        "reason": detail.get("reason", finding_type or "no reason provided"),
        "originalSource": source,
        "originalDetailType": detail_type,
        "findingType": finding_type,
    }

    # Existing demo/custom events
    if source == "demo.apply_auth" or detail_type == "ApplyAuthPolicy":
        response["applyAuth"] = True
        response["blockedArn"] = detail["blockedArn"]

    elif source == "demo.isolate_admin" or detail_type == "ShiftAdminRoute":
        response["shiftRoute"] = True
        response["path"] = detail.get("path", DEFAULT_ADMIN_PATH)
        response["ruleId"] = detail.get("ruleId", DEFAULT_ADMIN_RULE_ID)

    elif source == "demo.isolation_workflow" or detail_type == "IsolationWorkflow":
        response["applyAuth"] = detail.get("applyAuth", False)
        response["shiftRoute"] = detail.get("shiftRoute", False)

        if response["applyAuth"]:
            response["blockedArn"] = detail["blockedArn"]

        if response["shiftRoute"]:
            response["path"] = detail.get("path", DEFAULT_ADMIN_PATH)
            response["ruleId"] = detail.get("ruleId", DEFAULT_ADMIN_RULE_ID)

    # GuardDuty events
    elif source == "aws.guardduty" or source == "demo.guardduty":
        if finding_type in AUTH_FINDINGS:
            blocked_arn = extract_iam_role_arn(event, detail)

            if not blocked_arn:
                raise ValueError(f"Could not extract blockedArn from GuardDuty finding: {finding_type}")

            response["applyAuth"] = True
            response["blockedArn"] = blocked_arn

        elif finding_type in ROUTE_FINDINGS:
            response["shiftRoute"] = True
            response["path"] = DEFAULT_ADMIN_PATH
            response["ruleId"] = DEFAULT_ADMIN_RULE_ID
            response.update(extract_runtime_context(detail))

        else:
            print(f"No isolation action mapped for GuardDuty finding type: {finding_type}")

    if response["applyAuth"] and not response.get("blockedArn"):
        raise ValueError("applyAuth=true but no blockedArn was provided")

    if response["shiftRoute"] and not response.get("ruleId"):
        raise ValueError("shiftRoute=true but no ruleId was provided")

    print("router response:", json.dumps(response))
    return response