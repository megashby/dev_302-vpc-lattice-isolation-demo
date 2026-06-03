import json


def lambda_handler(event, context):
    print("router event:", json.dumps(event))

    source = event.get("source")
    detail_type = event.get("detail-type")
    detail = event.get("detail", {})

    response = {
        "applyAuth": False,
        "shiftRoute": False,
        "reason": detail.get("reason", "no reason provided"),
        "originalSource": source,
        "originalDetailType": detail_type,
    }

    if source == "demo.apply_auth" or detail_type == "ApplyAuthPolicy":
        response["applyAuth"] = True
        response["blockedArn"] = detail["blockedArn"]

    elif source == "demo.isolate_admin" or detail_type == "ShiftAdminRoute":
        response["shiftRoute"] = True

    elif source == "demo.isolation_workflow" or detail_type == "IsolationWorkflow":
        response["applyAuth"] = detail.get("applyAuth", False)
        response["shiftRoute"] = detail.get("shiftRoute", False)

        if response["applyAuth"]:
            response["blockedArn"] = detail["blockedArn"]

    if response["applyAuth"] and not response.get("blockedArn"):
        raise ValueError("applyAuth=true but no blockedArn was provided")

    print("router response:", json.dumps(response))
    return response