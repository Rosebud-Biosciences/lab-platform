"""Placeholder Dagster code location.

Deployed when the workloads module is given no dagster_user_code_image, so a
fresh platform has one asset to materialize and prove the control plane, run
launcher and metadata database work end to end. Replace it by pointing
dagster_user_code_image at your own image (see docs/preview-environments.md).
"""

import os

import dagster as dg


@dg.asset(
    description=(
        "Hello from the lab platform. Materializing this asset launches a run "
        "pod through the K8sRunLauncher and records it in the Dagster database. "
        "Set dagster_user_code_image to replace this code location."
    ),
)
def hello_platform() -> dg.MaterializeResult:
    return dg.MaterializeResult(
        metadata={
            "message": "hello from the lab platform",
            "pipeline_env": os.environ.get("PIPELINE_ENV", "unset"),
            "data_root": os.environ.get("DATA_ROOT", "unset"),
        }
    )


defs = dg.Definitions(assets=[hello_platform])
