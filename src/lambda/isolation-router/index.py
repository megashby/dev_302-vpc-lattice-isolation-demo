import json
import os
import time
from datetime import datetime, timezone

import boto3

logs = boto3.client("logs")
vpclattice = boto3.client("vpc-lattice")

ROUTE_FINDINGS = {
    "CryptoCurrency:Runtime/BitcoinTool.B",
    "Backdoor:Runtime/C&CActivity.B!DNS",
    "Impact:Runtime/CryptoMinerExecuted",
}

AUTH_FINDINGS = {
    "PrivilegeEscalation:IAMUser/AnomalousBehavior",
    "UnauthorizedAccess:IAMUser/AnomalousBehavior",
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration",
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.InsideAWS",
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
}

SENSITIVE_PATH_PREFIXES = [
    "/admin",
    "/internal",
    "/manage",
]

PRINCIPAL_SERVICE_MAP = {
    "arn:aws:iam::222441492902:role/demo-lattice-ecs-task-role-client-b": "orders-api",
}


def require(value, name):
    if value is None or value == "":
        raise ValueError(f"Missing required field: {name}")
    return value


def get_nested(obj, *keys):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def parse_detail(event):
    detail = event.get("detail", {})
    if isinstance(detail, str):
        return json.loads(detail)
    return detail


def extract_finding_type(detail):
    return require(detail.get("type"), "detail.type")


def extract_ecs_service_name(detail):
    task = get_nested(detail, "resource", "ecsClusterDetails", "taskDetails") or {}

    group = task.get("group")
    if group and group.startswith("service:"):
        return group.split("service:", 1)[1]

    definition_arn = task.get("definitionArn", "")
    if ":task-definition/" in definition_arn:
        family_revision = definition_arn.split(":task-definition/", 1)[1]
        return family_revision.split(":", 1)[0]

    raise ValueError("Unable to determine ECS service name from GuardDuty event")


def extract_task_ip(detail):
    network_action = get_nested(
        detail,
        "service",
        "action",
        "networkConnectionAction"
    )

    if network_action:
        ip = get_nested(network_action, "localIpDetails", "ipAddressV4")
        if ip:
            return ip

    return None


def extract_principal_arn(detail):
    access_key = get_nested(detail, "resource", "accessKeyDetails") or {}

    user_name = access_key.get("userName")
    if user_name and user_name.startswith("arn:aws:iam::"):
        return user_name

    principal_arn = access_key.get("principalArn")
    if principal_arn:
        return principal_arn

    raise ValueError("Unable to determine principal ARN from GuardDuty event")


def find_lattice_service_by_name(service_name):
    paginator = vpclattice.get_paginator("list_services")

    for page in paginator.paginate():
        for service in page.get("items", []):
            if service.get("name") == service_name:
                return service["id"]

    raise ValueError(f"No VPC Lattice service found with name: {service_name}")


def find_listener_for_service(service_id):
    paginator = vpclattice.get_paginator("list_listeners")

    for page in paginator.paginate(serviceIdentifier=service_id):
        for listener in page.get("items", []):
            if listener.get("protocol") == "HTTP" and listener.get("port") == 80:
                return listener["id"]

    raise ValueError(f"No HTTP:80 listener found for service {service_id}")


def normalize_path(path):
    if not path:
        return None

    if not path.startswith("/"):
        path = f"/{path}"

    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]

    return path


def rule_matches_path(rule, path):
    path = normalize_path(path)

    match = rule.get("match", {})
    http_match = match.get("httpMatch", {})
    path_match = http_match.get("pathMatch", {})
    matcher = path_match.get("match", {})

    exact = normalize_path(matcher.get("exact"))
    prefix = normalize_path(matcher.get("prefix"))

    if exact and exact == path:
        return True

    if prefix and path.startswith(prefix):
        return True

    return False


def find_rule_for_path(service_id, listener_id, path):
    paginator = vpclattice.get_paginator("list_rules")

    for page in paginator.paginate(
        serviceIdentifier=service_id,
        listenerIdentifier=listener_id
    ):
        for rule_summary in page.get("items", []):
            rule_id = rule_summary["id"]

            rule = vpclattice.get_rule(
                serviceIdentifier=service_id,
                listenerIdentifier=listener_id,
                ruleIdentifier=rule_id
            )

            print("candidate rule:", json.dumps({
                "ruleId": rule_id,
                "name": rule.get("name"),
                "priority": rule.get("priority"),
                "match": rule.get("match")
            }, default=str))

            if rule_matches_path(rule, path):
                return rule_id

    raise ValueError(f"No listener rule found matching path {path}")


def parse_lattice_log_message(message):
    try:
        return json.loads(message)
    except Exception:
        # logs tail often prefixes timestamp/stream before JSON. Try last JSON object.
        idx = message.find("{")
        if idx >= 0:
            return json.loads(message[idx:])
        raise


def log_event_matches_target(record, service_id, task_ip):
    service_arn = record.get("serviceArn", "")
    target_ip_port = record.get("targetIpPort", "")

    service_matches = service_id in service_arn
    target_matches = bool(task_ip and target_ip_port.startswith(f"{task_ip}:"))

    return service_matches and (target_matches or task_ip is None)


def path_priority(path):
    normalized = normalize_path(path) or ""

    for idx, prefix in enumerate(SENSITIVE_PATH_PREFIXES):
        if normalized.startswith(prefix):
            return 100 - idx

    return 1


def choose_best_path(paths):
    if not paths:
        return None

    unique_paths = sorted(set(normalize_path(p) for p in paths if p))

    sensitive = [
        p for p in unique_paths
        if any(p.startswith(prefix) for prefix in SENSITIVE_PATH_PREFIXES)
    ]

    if sensitive:
        return sorted(sensitive, key=path_priority, reverse=True)[0]

    return unique_paths[-1]


def find_recent_path_from_lattice_logs(service_id, task_ip):
    log_group = require(
        os.environ.get("LATTICE_ACCESS_LOG_GROUP"),
        "LATTICE_ACCESS_LOG_GROUP"
    )

    lookback_seconds = int(os.environ.get("LOG_LOOKBACK_SECONDS", "300"))
    end_ms = int(time.time() * 1000)
    start_ms = end_ms - (lookback_seconds * 1000)

    paths = []

    paginator = logs.get_paginator("filter_log_events")

    for page in paginator.paginate(
        logGroupName=log_group,
        startTime=start_ms,
        endTime=end_ms,
    ):
        for event in page.get("events", []):
            try:
                record = parse_lattice_log_message(event["message"])
            except Exception as exc:
                print(f"Skipping unparsable log event: {exc}")
                continue

            if not log_event_matches_target(record, service_id, task_ip):
                continue

            request_path = record.get("requestPath")
            if request_path:
                paths.append(request_path)

    chosen = choose_best_path(paths)

    print(json.dumps({
        "correlation": "lattice_access_logs",
        "taskIp": task_ip,
        "pathsSeen": paths,
        "chosenPath": chosen,
    }))

    if not chosen:
        raise ValueError(
            f"No recent VPC Lattice access log path found for service={service_id}, task_ip={task_ip}"
        )

    return chosen


def lambda_handler(event, context):
    print("router input:", json.dumps(event, default=str))

    detail = parse_detail(event)
    finding_type = extract_finding_type(detail)
    severity = detail.get("severity")

    result = {
        "findingType": finding_type,
        "severity": severity,
        "findingId": detail.get("id"),
        "applyAuth": False,
        "shiftRoute": False,
    }

    if finding_type in ROUTE_FINDINGS:
        ecs_service_name = extract_ecs_service_name(detail)
        service_id = find_lattice_service_by_name(ecs_service_name)
        listener_id = find_listener_for_service(service_id)

        task_ip = extract_task_ip(detail)
        path = find_recent_path_from_lattice_logs(service_id, task_ip)

        rule_id = find_rule_for_path(service_id, listener_id, path)

        result.update({
            "isolationAction": "ROUTE_ISOLATION",
            "shiftRoute": True,
            "ecsServiceName": ecs_service_name,
            "taskIp": task_ip,
            "path": path,
            "serviceIdentifier": service_id,
            "listenerIdentifier": listener_id,
            "ruleIdentifier": rule_id,
            "maintenanceTargetGroupIdentifier": require(
                os.environ.get("MAINTENANCE_TG_IDENTIFIER"),
                "MAINTENANCE_TG_IDENTIFIER"
            ),
        })

    elif finding_type in AUTH_FINDINGS:
        principal_arn = extract_principal_arn(detail)

        lattice_service_name = PRINCIPAL_SERVICE_MAP.get(principal_arn)
        if not lattice_service_name:
            raise ValueError(
                f"No protected Lattice service mapping for principal: {principal_arn}"
            )

        service_id = find_lattice_service_by_name(lattice_service_name)

        result.update({
            "isolationAction": "AUTH_DENY",
            "applyAuth": True,
            "blockedArn": principal_arn,
            "latticeServiceName": lattice_service_name,
            "serviceIdentifier": service_id,
        })

    else:
        result["isolationAction"] = "NO_ACTION"

    print("router output:", json.dumps(result, default=str))
    return result