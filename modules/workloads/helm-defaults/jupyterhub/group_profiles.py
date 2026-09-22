# Rendered by modules/workloads (jupyterhub_profiles.tf) into hub.extraConfig.
# A user is offered one server profile per IdP group of theirs that has one;
# the chosen profile's pod runs as the group's identity (see that file).
import json

from kubernetes_asyncio.client.models import V1EnvFromSource, V1SecretEnvSource, V1VolumeMount
from tornado import web

GROUP_PROFILES = json.loads(r"""${profiles_json}""")


def group_profile_list(spawner):
    groups = {g.name for g in spawner.user.groups}
    return [
        {
            "display_name": p["display_name"],
            "slug": p["slug"],
            "kubespawner_override": {
                "service_account": p["service_account"],
                "environment": p["env"],
                "extra_labels": p["labels"],
            },
        }
        for path, p in sorted(GROUP_PROFILES.items())
        if path in groups
    ]


def group_profile_pod(spawner, pod):
    slug = (spawner.user_options or {}).get("profile")
    path, profile = next(((path, p) for path, p in GROUP_PROFILES.items() if p["slug"] == slug), (None, None))
    if profile is None:
        return pod
    # KubeSpawner already refuses a profile it did not offer; check again here,
    # where the group's Secret and directory are about to be mounted.
    if path not in {g.name for g in spawner.user.groups}:
        raise web.HTTPError(403, f"{spawner.user.name} is not a member of {path}")
    container = pod.spec.containers[0]
    env_from = [] if profile["replace_identity"] else list(container.env_from or [])
    container.env_from = env_from + [V1EnvFromSource(secret_ref=V1SecretEnvSource(name=profile["secret"]))]
    mounts = list(container.volume_mounts or [])
    if not profile["mount_shared"]:
        mounts = [m for m in mounts if m.name != "jupyterhub-shared"]
    if profile["group_directory"]:
        mounts.append(V1VolumeMount(name="home", mount_path="/home/jovyan/group", sub_path=profile["subpath"]))
        for env in container.env or []:
            # The docker-stacks start script (running as root) chowns these.
            if env.name == "CHOWN_EXTRA":
                env.value = ",".join(v for v in [env.value, "/home/jovyan/group"] if v)
    container.volume_mounts = mounts
    return pod


c.KubeSpawner.profile_list = group_profile_list  # noqa: F821 (the hub's config object)
c.KubeSpawner.modify_pod_hook = group_profile_pod  # noqa: F821
