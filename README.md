# ASM Managed Control Plane (ASM MCP)

This repository contains a blueprint repository for installing the ASM MCP
client-side components in an ASM-MCP compliant cluster and GCP project.

The tools `kpt` and `anthoscli` are required in order to install the full sample.
If you intend to install ASM-MCP in an existing cluster, you will also need 
`kubectl`.

There are three subdirectories, each containing a portion of the installation.

- The `project` subfolder, which contains resources that configure GCP Project
level resources such as IAM roles and enabled APIs.

- The `cluster` subfolder, which contains resources that create and deploy an
ASM-MCP compatible GKE cluster.

- The `asm` subfolder, which contains the ASM-MCP cluster-side components.
At this time, this includes the following:
  - Network Endpoint Group controller - used to create GCP NEGs for cluster 
    services. This will eventually be removed as its functionality is replaced.
  - `asm-galley-push` - Used to push cluster state to the MCP.
  - `asm-td` - Used to inject sidecar configurations into pods.
  - Various RBAC resources, configmaps, secrets, and other plumbing to support
    the main deployments.
  - A post-install script used to configure the few resources which cannot be
    managed declaratively (which will be removed in the future)
  
# Installation

There are two methods for installing ASM MCP: as a greenfield GKE cluster, or as
a component in an existing cluster.

## Installing a new cluster

To install a new cluster, you must do the following:

```bash
#################################
# Install anthoscli and kpt
#################################
gcloud components install kpt
gcloud components install anthoscli (??) # TODO: Not sure where this comes from now

#################################
# Configure environment variables
#################################
export PROJECT_ID=${the project id}
export CLUSTER_NAME=my-cluster-name
# LOCATION can be a zone (for single zone clusters) or region (for regional)
export LOCATION=us-west1-b

#################################
# Fetch and configure blueprints
#################################
mkdir some/cluster/directory
cd some/cluster/directory
# To take full advantage of kpt, this should be a git repo. Run `git-init` or `git clone`
git init .

kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm@asm-networking asm
kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/project@asm-networking project
kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/cluster@asm-networking cluster

# To set tunables, use `kpt cfg set`. To see all tunables, run `kpt cfg list-setters <folder>`
kpt cfg set asm gcloud.compute.location ${LOCATION}
kpt cfg set asm gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set asm gcloud.core.project ${PROJECT_ID}

kpt cfg set cluster gcloud.compute.location ${LOCATION}
kpt cfg set cluster gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set cluster gcloud.core.project ${PROJECT_ID}

kpt cfg set project gcloud.compute.location ${LOCATION}
kpt cfg set project gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set project gcloud.core.project ${PROJECT_ID}

# Optional: commit state to git
# git add -u && git commit -m "Creating new ASM MCP cluster"

#################################
# Apply cluster state
#################################

# From `/some/cluster/directory` (the parent folder of the three kpt folders):
anthoscli apply --project=${PROJECT_ID} -f ./
PROJECT_ID=${PROJECT_ID} LOCATION=${LOCATION} CLUSTER_NAME=${CLUSTER_NAME} ./asm/infrastructure_configs.sh
```


## Installing on an existing cluster

To install on an existing cluster, do NOT use the `cluster` folder. Use  these
modified instructions:

```bash
#################################
# Install anthoscli and kpt
#################################
gcloud components install kpt
gcloud components install anthoscli (??) # TODO: Not sure where this comes from now

#################################
# Configure environment variables
#################################
export PROJECT_ID=${the project id}
export CLUSTER_NAME=my-cluster-name
# LOCATION can be a zone (for single zone clusters) or region (for regional)
export LOCATION=us-west1-b

#################################
# Fetch and configure blueprints
#################################
mkdir some/cluster/directory
cd some/cluster/directory
# To take full advantage of kpt, this should be a git repo. Run `git-init` or `git clone`
git init .

kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm@asm-networking asm
kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/project@asm-networking project

# To set tunables, use `kpt cfg set`. To see all tunables, run `kpt cfg list-setters <folder>`
kpt cfg set asm location ${LOCATION}
kpt cfg set asm cluster-name ${CLUSTER_NAME}
kpt cfg set asm gcloud.core.project ${PROJECT_ID}

kpt cfg set project gcloud.core.project ${PROJECT_ID}

# Optional: commit state to git
# git add -u && git commit -m "Creating new ASM MCP cluster"

#################################
# Apply cluster state
#################################

# From `/some/cluster/directory` (the parent folder of the three kpt folders):
anthoscli apply --project=${PROJECT_ID} -f ./project
kubectl apply -k ./asm
PROJECT_ID=${PROJECT_ID} LOCATION=${LOCATION} CLUSTER_NAME=${CLUSTER_NAME} ./asm/infrastructure_configs.sh
```

# Usage

To use the ASM MCP, you need to label your workload namespace as follows:

```bash
$> kubectl label ns my-workload-namespace istio.io/rev=asm-td
```

This will create a namespace label such as the following:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-workload-namespace
  labels:
    istio.io/rev: asm-td
```



