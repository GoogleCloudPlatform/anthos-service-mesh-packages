#!/usr/bin/env bash

_common_setup() {
    source "node_modules/bats-support/load.bash"
    source "node_modules/bats-assert/load.bash"

    while read -r SOURCE_FILE; do
        source "$SOURCE_FILE"
    done <<EOF
${SOURCE_FILES}
EOF
}

# This function helps setup the command line tests by intercepting and mocking CLI tools that
# either requires real querying/networking or are unnecessary
#
# Command intercepted: gcloud, kubectl, istioctl, nc, fatal, warn_parse, warn, list_valid_pools, sleep, curl, tar, kpt
#
_intercept_setup() {
    ### Test Helper Functions ###
    kubectl() {
        local RETVAL; RETVAL=0;
        echo "Intercepted kubectl ${*}" >&2
        kubectl_intercept ${@} || RETVAL="${?}"
        return "${RETVAL}"
    }

    gcloud() {
        local RETVAL; RETVAL=0;
        echo "Intercepted gcloud ${*}" >&2
        gcloud_intercept ${@} || RETVAL="${?}"
        return "${RETVAL}"
    }

    istioctl() {
      local RETVAL; RETVAL=0;
      echo "Intercepted istioctl ${*}" >&2
      istioctl_intercept ${@} || RETVAL="${?}"
      return "${RETVAL}"
    }

    nc() {
        return 0
    }

    FATAL_EXITS=1
    fatal() {
        echo "[FATAL(fake)]: ${1}" >&2
        if [[ "${FATAL_EXITS}" -eq 1 ]]; then
            exit 1
        fi
    }

    WARNED=0
    warn_pause() {
        echo "[WARNING(fake)]: ${1}" >&2
        WARNED=1
    }

    warn() {
        echo "[WARNING(fake)]: ${1}" >&2
        WARNED=1
    }

    NODE_POOL=""
    list_valid_pools() {
        echo "${NODE_POOL}"
    }

    sleep() {
        echo "sleeping ${*}" >&2
    }

    curl() {
        return 0
    }

    tar() {
        return 0
    }

    kpt() {
        if [[ "${1}" = "version" ]]; then
          echo "1.0.0"
        fi
        return 0
    }

    is_autopilot() {
      false
    }
}

gcloud_intercept() {
  if [[ "${*}" == *"machineType"* ]]; then
    cat <<EOF
[
  {
    "config": {
      "machineType": "e2-standard-4"
    },
    "initialNodeCount": 4,
    "name": "default-pool"
  },
  {
    "config": {
      "machineType": "e2-medium-1"
    },
    "initialNodeCount": 1,
    "name": "nondefault-pool"
  }
]
EOF
    return 0
  fi
  if [[ "${*}" == *"get-credentials"* ]]; then
    echo "this_should_pass"
    echo "${*}" >| "${KUBECONFIG}"
    return 0
  fi
  if [[ "${*}" == *"auth list"* ]]; then
    if [[ "${*}" == *"sa"* ]]; then
      echo "account@project.iam.gserviceaccount.com"
      return 0
    fi
    if [[ "${*}" == *"notloggedin"* ]]; then
      return 1
    fi
    echo "user@domain"
    return 0
  fi
  if [[ "${*}" == *"this_should_fail"* ]]; then
    return 1
  fi

  if [[ "${*}" == *"get-iam-policy"*"owner_this_should_pass"* ]]; then
    echo roles/owner
    return 0
  fi

  if [[ "${*}" == *"get-iam-policy"*"this_should_pass"* ]]; then
    cat <<EOF
roles/servicemanagement.admin
roles/serviceusage.serviceUsageAdmin
roles/meshconfig.admin
roles/compute.admin
roles/container.admin
roles/resourcemanager.projectIamAdmin
roles/iam.serviceAccountAdmin
roles/iam.serviceAccountKeyAdmin
roles/gkehub.admin
roles/privateca.admin
EOF
    return 0
  fi

  if [[ "${*}" == *"this_should_pass"*"resourceLabel"* ]]; then
    echo 'mesh_id=proj-this_should_pass'
    return 0
  fi

  if [[ "${*}" == *"describe"*"this_should_pass"*"json"* ]]; then
  cat <<EOF
{
  "loggingService": "logging.googleapis.com/kubernetes",
  "monitoringService": "monitoring.googleapis.com/kubernetes",
  "workloadIdentityConfig": "definitely_enabled"
}
EOF
    return 0
  fi

  if [[ "${*}" == *"services list --enabled"*"this_should_pass" ]]; then
    cat <<EOF
mesh.googleapis.com
EOF
  return 0
  fi
  if [[ "${*}" == *"hub memberships list"* ]]; then
    cat <<EOF
[
  {
    "authority": {
      "identityProvider": "https://container.googleapis.com/projects/this_should_pass/locations/this_should_pass/clusters/this_should_pass",
      "issuer": "https://kubernetes.default.svc.cluster.local",
      "oidcJwks": "dummy",
      "workloadIdentityPool": "this_should_pass.svc.id.goog"
    },
  }
]
EOF
    return 0
  fi
  if [[ "${*}" == *"this_should_pass"* ]]; then
    echo "this_should_pass"
    return 0
  fi
  if [[ "${*}" == *"core/account"* ]]; then
    echo "this_should_pass"
    return 0
  fi

  return 1
}

kubectl_intercept() {
  FAKE_CONFIG="$(cat "${KUBECONFIG}" 2>/dev/null)"

  if [[ "${*}" == *"config"*"current-context"* ]]; then
    if [[ "${FAKE_CONFIG}" == *"get-credentials"*"this_should_pass"* ]]; then
      echo "gke_this-should-pass_this-should-pass_this-should-pass"
      return 0
    elif [[ "${FAKE_CONFIG}" == *"get-credentials"*"this_should_fail"* ]]; then
      echo "gke_this-should-fail_this-should-fail_this-should-fail"
      return 0
    fi
  fi
  if [[ "${*}" == *"config"* ]]; then
    cat <<-EOF
{
    "clusters": [
        {
            "cluster": {
                "server": "https://127.0.0.1"
            }
        }
    ]
}
EOF
  return 0
  fi
  if [[ "${*}" == *"version"* ]]; then
    cat <<EOF
{
  "clientVersion": {
    "major": "1",
    "minor": "19",
    "gitVersion": "v1.19.2",
    "gitCommit": "f5743093fd1c663cb0cbc89748f730662345d44d",
    "gitTreeState": "clean",
    "buildDate": "2020-09-16T13:41:02Z",
    "goVersion": "go1.15",
    "compiler": "gc",
    "platform": "linux/amd64"
  },
  "serverVersion": {
    "major": "1",
    "minor": "16+",
    "gitVersion": "v1.16.12-gke.1337",
    "gitCommit": "c56469002ffea532564027018cc503fdea159974",
    "gitTreeState": "clean",
    "buildDate": "2020-09-21T09:20:42Z",
    "goVersion": "go1.12.17b4",
    "compiler": "gc",
    "platform": "linux/amd64"
  }
}
EOF
    return 0
  fi
  if [[ "${*}" == *"ns"* ]]; then
    cat <<EOF
NAME              STATUS   AGE
default           Active   53d
foo               Active   51d
gke-connect       Active   53d
istio-system      Active   37m
kube-node-lease   Active   53d
kube-public       Active   53d
kube-system       Active   53d
EOF
    return 0
  fi
  if [[ "${*}" == *"clusterrolebinding"*"this_should_pass"* ]]; then
    echo '[cluster-admin]'
    return 0
  fi
  if [[ "${*}" == *"--api-group=hub.gke.io"* ]]; then
    cat <<EOF
NAME          SHORTNAMES   APIGROUP     NAMESPACED   KIND
memberships                hub.gke.io   false        Membership
EOF
    return 0
  fi
  if [[ "${*}" == *"memberships.hub.gke.io -ojsonpath={..metadata.name}"* ]]; then
    echo 'membership'
    return 0
  fi
  if [[ "${*}" == *"memberships.hub.gke.io membership -o=json"* ]]; then
    cat <<EOF
{
    "apiVersion": "hub.gke.io/v1",
    "kind": "Membership",
    "spec": {
        "identity_provider": "https://container.googleapis.com/v1/projects/this_should_pass/locations/this_should_pass/clusters/this_should_pass",
        "owner": {
            "id": "//gkehub.googleapis.com/projects/this_should_pass/locations/global/memberships/this_should_pass"
        },
        "workload_identity_pool": "this_should_pass.svc.id.goog"
    }
}
EOF
    return 0
  fi
  if [[ "${FAKE_CONFIG}" == *"has_istio"*"right_namespace"*  ]]; then
    echo "istiod"
    return 0
  fi
  if [[ "${FAKE_CONFIG}" == *"has_istio"*"wrong_namespace"* ]]; then
    if [[ "${*}" == *"istio-system"* ]]; then
      return 0
    fi
    echo "istiod"
    return 0
  fi
}

istioctl_intercept() {
  if [[ "${*}" == "create-remote-secret"*"this-should-pass" ]]; then
    return 0
  fi

  return 1
}
