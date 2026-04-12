"""Orphan cleanup Lambda for DIALED shared tier.

Invoked by the pr-cleanup workflow when `terraform destroy` fails. Finds
AWS resources tagged with the PR's workspace that have been left behind
and removes them.

Event shape::

    {"workspace": "dev-pr-42", "pr_number": "42", "environment": "dev"}

v1 scope: network interfaces (ENIs) and security groups. M2 extends this
to drop the per-PR Postgres database created by the per_pr_database
module.
"""

import json
import logging
import os
import time

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")


def handler(event, context):
    workspace = event.get("workspace")
    pr_number = event.get("pr_number")
    environment = event.get("environment")

    if not workspace:
        raise ValueError("event.workspace is required")

    log.info(
        "cleanup start: workspace=%s pr=%s env=%s", workspace, pr_number, environment
    )

    results = {
        "workspace": workspace,
        "enis_deleted": [],
        "sgs_deleted": [],
        "errors": [],
    }

    _delete_orphan_enis(workspace, results)
    _delete_orphan_sgs(workspace, results)

    # Hook for M2: drop the per-PR DB when the database module is present.
    # Intentionally no-op in v1 — activated when the Postgres provider
    # wiring is added by `dialed:add-module database`.
    _drop_pr_database_stub(workspace, pr_number, results)

    log.info("cleanup done: %s", json.dumps(results))
    return results


def _delete_orphan_enis(workspace, results):
    try:
        paginator = ec2.get_paginator("describe_network_interfaces")
        for page in paginator.paginate(
            Filters=[
                {"Name": "tag:Workspace", "Values": [workspace]},
                {"Name": "status", "Values": ["available"]},
            ]
        ):
            for eni in page.get("NetworkInterfaces", []):
                eni_id = eni["NetworkInterfaceId"]
                try:
                    ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                    results["enis_deleted"].append(eni_id)
                    log.info("deleted ENI %s", eni_id)
                except Exception as e:  # noqa: BLE001
                    results["errors"].append(f"eni {eni_id}: {e}")
    except Exception as e:  # noqa: BLE001
        results["errors"].append(f"describe_network_interfaces: {e}")


def _delete_orphan_sgs(workspace, results):
    try:
        paginator = ec2.get_paginator("describe_security_groups")
        candidates = []
        for page in paginator.paginate(
            Filters=[{"Name": "tag:Workspace", "Values": [workspace]}]
        ):
            candidates.extend(page.get("SecurityGroups", []))

        # Delete in two passes: first pass often fails because of
        # cross-referencing rules; a short pause then a second pass picks
        # up what's become eligible.
        for attempt in (1, 2):
            remaining = []
            for sg in candidates:
                sg_id = sg["GroupId"]
                if sg_id in results["sgs_deleted"]:
                    continue
                try:
                    ec2.delete_security_group(GroupId=sg_id)
                    results["sgs_deleted"].append(sg_id)
                    log.info("deleted SG %s (pass %d)", sg_id, attempt)
                except Exception as e:  # noqa: BLE001
                    if attempt == 1:
                        remaining.append(sg)
                    else:
                        results["errors"].append(f"sg {sg_id}: {e}")
            if not remaining:
                break
            candidates = remaining
            time.sleep(5)
    except Exception as e:  # noqa: BLE001
        results["errors"].append(f"describe_security_groups: {e}")


def _drop_pr_database_stub(workspace, pr_number, results):
    # Activated in M2 by dialed:add-module database, which sets the
    # DIALED_DB_CLUSTER_ENDPOINT / DIALED_DB_MASTER_SECRET_ARN env vars
    # on this Lambda's configuration. When unset, do nothing.
    cluster = os.environ.get("DIALED_DB_CLUSTER_ENDPOINT")
    secret = os.environ.get("DIALED_DB_MASTER_SECRET_ARN")
    if not cluster or not secret or not pr_number:
        log.debug("database module not wired — skipping DB drop")
        return
    results.setdefault("database", {"status": "skipped_v1_stub"})
