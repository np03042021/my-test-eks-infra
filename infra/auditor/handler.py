"""Daily security auditor.

Pure rule functions (no AWS calls, unit-tested) are kept separate from the thin boto3
adapter in handler(). boto3 is imported lazily inside handler() so tests need neither
the AWS SDK nor credentials.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALLOWED_PUBLIC_PORTS = frozenset({80, 443})
WORLD_V4 = "0.0.0.0/0"
WORLD_V6 = "::/0"
MAX_KEY_AGE = timedelta(days=90)


# ---------------------------------------------------------------- pure rules

def _port_label(perm: dict[str, Any]) -> str | None:
    """Return a label for the exposed ports, or None if the rule only exposes 80/443."""
    protocol = str(perm.get("IpProtocol", ""))
    if protocol == "-1":
        return "ALL"  # all protocols, all ports
    from_port, to_port = perm.get("FromPort"), perm.get("ToPort")
    if from_port is None or to_port is None or from_port == -1:
        return protocol  # e.g. icmp with no port range
    if from_port == to_port and from_port in ALLOWED_PUBLIC_PORTS:
        return None
    return str(from_port) if from_port == to_port else f"{from_port}-{to_port}"


def find_open_security_groups(security_groups: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Flag ingress rules open to 0.0.0.0/0 or ::/0 on anything other than port 80 or 443."""
    findings = []
    for sg in security_groups:
        for perm in sg.get("IpPermissions", []):
            open_cidrs = [r["CidrIp"] for r in perm.get("IpRanges", []) if r.get("CidrIp") == WORLD_V4]
            open_cidrs += [r["CidrIpv6"] for r in perm.get("Ipv6Ranges", []) if r.get("CidrIpv6") == WORLD_V6]
            if not open_cidrs:
                continue
            ports = _port_label(perm)
            if ports is None:
                continue
            findings.append({
                "rule": "SG_OPEN_TO_WORLD",
                "group_id": sg.get("GroupId"),
                "group_name": sg.get("GroupName"),
                "vpc_id": sg.get("VpcId"),
                "protocol": perm.get("IpProtocol"),
                "ports": ports,
                "cidrs": open_cidrs,
            })
    return findings


def _mask(key_id: str) -> str:
    """Never log a full access key ID."""
    return f"{key_id[:4]}...{key_id[-4:]}" if len(key_id) > 8 else "****"


def find_stale_access_keys(keys: Iterable[dict[str, Any]], now: datetime) -> list[dict[str, Any]]:
    """Flag ACTIVE IAM access keys older than 90 days. `now` is injected for testability."""
    findings = []
    for key in keys:
        if key.get("Status") != "Active":
            continue
        age = now - key["CreateDate"]
        if age > MAX_KEY_AGE:
            findings.append({
                "rule": "IAM_ACCESS_KEY_OLDER_THAN_90_DAYS",
                "user": key.get("UserName"),
                "access_key_id": _mask(key.get("AccessKeyId", "")),
                "age_days": age.days,
            })
    return findings


def find_public_eks_endpoints(clusters: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Flag EKS clusters whose public API endpoint accepts 0.0.0.0/0."""
    findings = []
    for cluster in clusters:
        vpc_cfg = cluster.get("resourcesVpcConfig", {})
        if vpc_cfg.get("endpointPublicAccess") and WORLD_V4 in vpc_cfg.get("publicAccessCidrs", []):
            findings.append({
                "rule": "EKS_PUBLIC_ENDPOINT_OPEN_TO_WORLD",
                "cluster": cluster.get("name"),
                "public_access_cidrs": vpc_cfg.get("publicAccessCidrs", []),
            })
    return findings


# ---------------------------------------------------------------- AWS adapter

def _paginate(client: Any, operation: str, result_key: str, **kwargs: Any) -> list[Any]:
    items: list[Any] = []
    for page in client.get_paginator(operation).paginate(**kwargs):
        items.extend(page.get(result_key, []))
    return items


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    import boto3  # lazy import: keeps the pure rules testable without the SDK

    ec2 = boto3.client("ec2")
    iam = boto3.client("iam")
    eks = boto3.client("eks")

    security_groups = _paginate(ec2, "describe_security_groups", "SecurityGroups")

    keys: list[dict[str, Any]] = []
    for user in _paginate(iam, "list_users", "Users"):
        keys.extend(_paginate(iam, "list_access_keys", "AccessKeyMetadata", UserName=user["UserName"]))

    clusters = [eks.describe_cluster(name=name)["cluster"]
                for name in _paginate(eks, "list_clusters", "clusters")]

    findings = (
        find_open_security_groups(security_groups)
        + find_stale_access_keys(keys, now=datetime.now(timezone.utc))
        + find_public_eks_endpoints(clusters)
    )

    # One structured log line per finding: easy to alert on with a CloudWatch metric filter.
    for finding in findings:
        logger.warning(json.dumps(finding))

    summary = {
        "finding_count": len(findings),
        "checked": {
            "security_groups": len(security_groups),
            "access_keys": len(keys),
            "eks_clusters": len(clusters),
        },
        "findings": findings,
    }
    logger.info(json.dumps({k: v for k, v in summary.items() if k != "findings"}))
    return summary
