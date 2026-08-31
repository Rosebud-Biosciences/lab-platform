"""Dagster orchestrating an ephemeral Ray cluster.

Same primitive as the Argo example (``../rayjob.yaml``): a Dagster op creates a
KubeRay ``RayJob`` and polls it to completion. ``shutdownAfterJobFinishes`` means
KubeRay provisions a dedicated Ray cluster for this run and tears it back down
when the entrypoint exits, so the op only has to submit and wait.

Prereqs (workloads module): ``enable_ray = true`` and ``enable_dagster = true``.
That provisions namespace ``<name_prefix>ray`` and gives the Dagster service
account (``<name_prefix>dagster:dagster``) a ClusterRole with ``rayjobs`` perms,
so the Dagster daemon can create RayJobs in the Ray namespace.

Run inside the cluster (the Dagster deployment already mounts its service
account), or locally against your kubeconfig:

    pip install dagster kubernetes
    dagster dev -f ephemeral_ray.py
"""

from __future__ import annotations

import time

from dagster import Config, OpExecutionContext, job, op
from kubernetes import client, config

RAY_NAMESPACE = "ray"  # "<name_prefix>ray" for a stamped/preview environment
RAY_IMAGE = "rayproject/ray:2.55.1"
RAY_VERSION = "2.55.1"

GROUP = "ray.io"
VERSION = "v1"
PLURAL = "rayjobs"


class EphemeralRayConfig(Config):
    entrypoint: str = 'python -c "import ray; ray.init(); print(ray.cluster_resources())"'
    namespace: str = RAY_NAMESPACE
    worker_replicas: int = 2
    poll_seconds: int = 10
    timeout_seconds: int = 1800


def _rayjob_manifest(cfg: EphemeralRayConfig, name: str) -> dict:
    """The ephemeral-cluster spec. Mirrors ../rayjob.yaml."""
    pod_resources = {
        "requests": {"cpu": "1", "memory": "2Gi"},
        "limits": {"memory": "3Gi"},
    }
    return {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "RayJob",
        "metadata": {"name": name},
        "spec": {
            "shutdownAfterJobFinishes": True,
            "ttlSecondsAfterFinished": 120,
            "entrypoint": cfg.entrypoint,
            "rayClusterSpec": {
                "rayVersion": RAY_VERSION,
                "headGroupSpec": {
                    "rayStartParams": {},
                    "template": {
                        "spec": {
                            "serviceAccountName": "ray-s3-sa",
                            "containers": [
                                {
                                    "name": "ray-head",
                                    "image": RAY_IMAGE,
                                    "resources": pod_resources,
                                }
                            ],
                        }
                    },
                },
                "workerGroupSpecs": [
                    {
                        "groupName": "workers",
                        "replicas": cfg.worker_replicas,
                        "minReplicas": 0,
                        "maxReplicas": max(cfg.worker_replicas, 4),
                        "rayStartParams": {},
                        "template": {
                            "spec": {
                                "serviceAccountName": "ray-s3-sa",
                                "containers": [
                                    {
                                        "name": "ray-worker",
                                        "image": RAY_IMAGE,
                                        "resources": pod_resources,
                                    }
                                ],
                            }
                        },
                    }
                ],
            },
        },
    }


def _load_kube_config() -> None:
    """In-cluster when running as the Dagster daemon, else local kubeconfig."""
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()


@op
def run_ephemeral_ray_job(context: OpExecutionContext, cfg: EphemeralRayConfig) -> str:
    _load_kube_config()
    api = client.CustomObjectsApi()

    name = f"ephemeral-dagster-{context.run_id[:8]}"
    manifest = _rayjob_manifest(cfg, name)

    context.log.info(f"Creating RayJob {cfg.namespace}/{name}")
    api.create_namespaced_custom_object(
        group=GROUP,
        version=VERSION,
        namespace=cfg.namespace,
        plural=PLURAL,
        body=manifest,
    )

    deadline = time.monotonic() + cfg.timeout_seconds
    terminal = {"SUCCEEDED", "FAILED"}
    try:
        while True:
            obj = api.get_namespaced_custom_object_status(
                group=GROUP,
                version=VERSION,
                namespace=cfg.namespace,
                plural=PLURAL,
                name=name,
            )
            status = obj.get("status", {})
            job_status = status.get("jobStatus", "PENDING")
            deployment_status = status.get("jobDeploymentStatus", "Initializing")
            context.log.info(f"RayJob {name}: jobStatus={job_status} ({deployment_status})")

            if job_status in terminal:
                if job_status == "FAILED":
                    raise RuntimeError(f"RayJob {name} failed: {status.get('message')}")
                return name

            if time.monotonic() > deadline:
                raise TimeoutError(f"RayJob {name} did not finish within {cfg.timeout_seconds}s")

            time.sleep(cfg.poll_seconds)
    finally:
        # shutdownAfterJobFinishes tears down the Ray cluster; deleting the
        # RayJob object cleans up the record too (defensive on failure paths).
        try:
            api.delete_namespaced_custom_object(
                group=GROUP,
                version=VERSION,
                namespace=cfg.namespace,
                plural=PLURAL,
                name=name,
            )
        except client.exceptions.ApiException:
            pass


@job
def ephemeral_ray_job():
    run_ephemeral_ray_job()
