import sys
import types
from datetime import datetime, timedelta, timezone

import pytest

import handler

NOW = datetime(2026, 10, 28, tzinfo=timezone.utc)


def sg(*perms, group_id="sg-1"):
    return {"GroupId": group_id, "GroupName": "test", "VpcId": "vpc-1", "IpPermissions": list(perms)}


def perm(protocol="tcp", from_port=22, to_port=22, v4=("0.0.0.0/0",), v6=()):
    return {
        "IpProtocol": protocol,
        "FromPort": from_port,
        "ToPort": to_port,
        "IpRanges": [{"CidrIp": c} for c in v4],
        "Ipv6Ranges": [{"CidrIpv6": c} for c in v6],
    }


# ------------------------------------------------------------ security groups

def test_ssh_open_to_world_is_flagged():
    [f] = handler.find_open_security_groups([sg(perm(from_port=22, to_port=22))])
    assert f["rule"] == "SG_OPEN_TO_WORLD"
    assert f["ports"] == "22"


def test_ipv6_world_is_flagged():
    [f] = handler.find_open_security_groups([sg(perm(from_port=3389, to_port=3389, v4=(), v6=("::/0",)))])
    assert f["cidrs"] == ["::/0"]


@pytest.mark.parametrize("port", [80, 443])
def test_http_and_https_are_allowed(port):
    assert handler.find_open_security_groups([sg(perm(from_port=port, to_port=port))]) == []


def test_all_traffic_rule_reports_all():
    [f] = handler.find_open_security_groups([sg(perm(protocol="-1", from_port=None, to_port=None))])
    assert f["ports"] == "ALL"


def test_range_spanning_80_to_443_is_flagged():
    [f] = handler.find_open_security_groups([sg(perm(from_port=80, to_port=443))])
    assert f["ports"] == "80-443"


def test_restricted_cidr_is_not_flagged():
    assert handler.find_open_security_groups([sg(perm(v4=("10.0.0.0/8",)))]) == []


def test_icmp_open_to_world_is_flagged():
    [f] = handler.find_open_security_groups([sg(perm(protocol="icmp", from_port=-1, to_port=-1))])
    assert f["ports"] == "icmp"


# ------------------------------------------------------------ IAM access keys

def key(days_old, status="Active", key_id="AKIAEXAMPLEKEY123456"):
    return {"UserName": "alice", "AccessKeyId": key_id, "Status": status,
            "CreateDate": NOW - timedelta(days=days_old)}


def test_active_key_older_than_90_days_is_flagged():
    [f] = handler.find_stale_access_keys([key(91)], now=NOW)
    assert f["age_days"] == 91


def test_key_id_is_masked_in_findings():
    [f] = handler.find_stale_access_keys([key(200)], now=NOW)
    assert f["access_key_id"] == "AKIA...3456"


def test_inactive_old_key_is_ignored():
    assert handler.find_stale_access_keys([key(400, status="Inactive")], now=NOW) == []


def test_key_at_90_days_is_not_flagged():
    assert handler.find_stale_access_keys([key(90)], now=NOW) == []


# ------------------------------------------------------------ EKS endpoints

def cluster(public, cidrs):
    return {"name": "c1", "resourcesVpcConfig": {"endpointPublicAccess": public, "publicAccessCidrs": cidrs}}


def test_public_endpoint_open_to_world_is_flagged():
    [f] = handler.find_public_eks_endpoints([cluster(True, ["0.0.0.0/0"])])
    assert f["cluster"] == "c1"


def test_public_endpoint_restricted_to_ip_is_ok():
    assert handler.find_public_eks_endpoints([cluster(True, ["203.0.113.7/32"])]) == []


def test_private_only_endpoint_is_ok():
    assert handler.find_public_eks_endpoints([cluster(False, ["0.0.0.0/0"])]) == []


# ------------------------------------------------------------ handler wiring (fake boto3)

class FakePaginator:
    def __init__(self, pages):
        self._pages = pages

    def paginate(self, **kwargs):
        return self._pages(**kwargs)


class FakeClient:
    def __init__(self, service):
        self.service = service

    def get_paginator(self, op):
        data = {
            "describe_security_groups": lambda **_: [{"SecurityGroups": [sg(perm(from_port=22, to_port=22))]}],
            "list_users": lambda **_: [{"Users": [{"UserName": "alice"}]}],
            "list_access_keys": lambda **kw: [{"AccessKeyMetadata": [
                {**key(120), "CreateDate": datetime.now(timezone.utc) - timedelta(days=120)}]}],
            "list_clusters": lambda **_: [{"clusters": ["c1"]}],
        }
        return FakePaginator(data[op])

    def describe_cluster(self, name):
        return {"cluster": cluster(True, ["0.0.0.0/0"])}


def test_handler_combines_all_rules(monkeypatch):
    fake_boto3 = types.SimpleNamespace(client=lambda service: FakeClient(service))
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)

    result = handler.handler({}, None)

    assert result["finding_count"] == 3
    assert {f["rule"] for f in result["findings"]} == {
        "SG_OPEN_TO_WORLD", "IAM_ACCESS_KEY_OLDER_THAN_90_DAYS", "EKS_PUBLIC_ENDPOINT_OPEN_TO_WORLD"}
    assert result["checked"] == {"security_groups": 1, "access_keys": 1, "eks_clusters": 1}
