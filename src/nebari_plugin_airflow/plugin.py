import base64
import os

from kubernetes import client, config
from typing import Any, List, Dict, Optional, Union

from cryptography.fernet import Fernet
from nebari.schema import Base
from _nebari.stages.base import NebariTerraformStage


class AirflowIngressConfig(Base):
    enabled: Optional[bool] = True
    path: Optional[str] = "/airflow"


class AirflowAuthConfig(Base):
    enabled: Optional[bool] = True


class AirflowAffinitySelectorConfig(Base):
    default: str


class AirflowAffinityConfig(Base):
    enabled: Optional[bool] = True
    selector: Union[AirflowAffinitySelectorConfig, str] = "general"


class AirflowGitSyncConfig(Base):
    enabled: Optional[bool] = False
    repo: Optional[str] = None
    path: Optional[str] = None
    branch: Optional[str] = "main"


class AirflowEnvConfig(Base):
    name: str
    value: str


class AirflowConfig(Base):
    name: Optional[str] = "airflow"
    namespace: Optional[str] = None
    pythonVersion: Optional[str] = "3.10"
    ingress: AirflowIngressConfig = AirflowIngressConfig()
    auth: AirflowAuthConfig = AirflowAuthConfig()
    affinity: AirflowAffinityConfig = AirflowAffinityConfig()
    extraEnv: Optional[List[AirflowEnvConfig]] = []
    gitSync: Optional[AirflowGitSyncConfig] = AirflowGitSyncConfig()
    values: Optional[Dict[str, Any]] = {}


class InputSchema(Base):
    airflow: AirflowConfig = AirflowConfig()


def get_secret_value(name: str, namespace: str, key: str, kubeconfig: str = None):
    try:
        config.load_kube_config(config_file=kubeconfig)
        v1 = client.CoreV1Api()
        sec = v1.read_namespaced_secret(name, namespace).data
        return base64.b64decode(sec[key]).decode("utf-8")
    except Exception as e:
        print(f"[Airflow] > Unable to lookup existing key from secret [{namespace}-{name}/{key}] {e}")
        return ""


class AirflowStage(NebariTerraformStage):
    name = "airflow"
    priority = 100

    input_schema = InputSchema

    def input_vars(self, stage_outputs: Dict[str, Dict[str, Any]]):
        domain = stage_outputs["stages/04-kubernetes-ingress"]["domain"]

        keycloak_url = ""
        realm_id = ""
        if self.config.airflow.auth.enabled:
            keycloak_url = (
                f"{stage_outputs['stages/05-kubernetes-keycloak']['keycloak_credentials']['value']['url']}/auth/"
            )
            realm_id = stage_outputs["stages/06-kubernetes-keycloak-configuration"]["realm_id"]["value"]

        chart_ns = self.config.airflow.namespace
        create_ns = True
        if chart_ns == None or chart_ns == "" or chart_ns == self.config.namespace:
            chart_ns = self.config.namespace
            create_ns = False

        kubeconfig = stage_outputs["stages/02-infrastructure"]["kubeconfig_filename"]["value"]
        fernet_key = get_secret_value(
            f"{self.config.airflow.name}-plugin-envs", chart_ns, "AIRFLOW__CORE__FERNET_KEY", kubeconfig
        )
        if fernet_key == None or fernet_key == "":
            fernet_key = Fernet.generate_key().decode()
        else:
            print(f"[Airflow] > Reusing existing fernet key")

        return {
            "name": self.config.airflow.name,
            "domain": domain,
            "realm_id": realm_id,
            "client_id": self.config.airflow.name,
            "base_url": f"https://{domain}{self.config.airflow.ingress.path}",
            "external_url": keycloak_url,
            "valid_redirect_uris": [f"https://{domain}{self.config.airflow.ingress.path}/oauth-authorized/keycloak"],
            "create_namespace": create_ns,
            "namespace": chart_ns,
            "overrides": self.config.airflow.values,
            "ingress": {"enabled": self.config.airflow.ingress.enabled, "path": self.config.airflow.ingress.path},
            "affinity": {
                "enabled": self.config.airflow.affinity.enabled,
                "selector": self.config.airflow.affinity.selector.__dict__
                if isinstance(self.config.airflow.affinity.selector, AirflowAffinitySelectorConfig)
                else self.config.airflow.affinity.selector,
            },
            "auth_enabled": self.config.airflow.auth.enabled,
            "fernet_key": fernet_key,
            "extraEnv": [x.__dict__ for x in self.config.airflow.extraEnv]
            if len(self.config.airflow.extraEnv) > 0
            else [],
            "gitSync": {
                "enabled": True,
                "repo": self.config.airflow.gitSync.repo,
                "path": self.config.airflow.gitSync.path,
                "branch": self.config.airflow.gitSync.branch,
                "credentials": {
                    "username": os.getenv("GITHUB_USERNAME", "_"),
                    "password": os.getenv("GITHUB_TOKEN", "_"),
                },
            }
            if self.config.airflow.gitSync != None and self.config.airflow.gitSync.enabled
            else {},
            "pythonVersion": self.config.airflow.pythonVersion,
        }
