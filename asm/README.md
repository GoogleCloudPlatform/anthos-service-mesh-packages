# Istio 1.5 example

The install is using Istiod, using the 'multi-controlplane' capability.
The install will create a deployment that coexists with OSS or other installations
of Istio. 

You can target a namespace to use Istio15 by adding the label:


```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myname
  labels:
    istio-env: istiodasm15
```

For using Traffic Director in a namespace you use the 'istiotd' label:


```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myname
  labels:
    istio-env: istiodtd
```

# Configure project and cluster

This step will:
- optionally configure the GCP project 
- optionally create the cluster and nodepool
- create cluster-wide resources and permissions

## Using anthoscli

```shell script
kpt config list-setters manifests/
## Set any configuration you want here, using e.g.
# kpt config set cluster-name my-new-cluster

anthoscli apply --project my-project -f samples/asm-istiod-15
```

## Using a script

```shell script
# TODO - cluster create shell script

# To preview kustomize output:
kubectl kustomize samples/asm-istiod-15

# If kustomize output is not correct, you can add kustomize patches.
# See 'istio-galley-config-td.yaml.patch' and the top `kustomization.yaml` 
# for an example

# Once the preview output looks correct, you can apply it with:
kubectl apply -k samples/asm-istiod-15
```

## Existing cluster, controlplane only

For an existing project and cluster:

```shell script
# See script output above for example of how to patch with kustomize
kubectl apply -k samples/asm-istiod-15/trafficdirector samples/asm-istiod-15/cluster
```

# Installing a test app
To run a test app:

```shell script
kubectl apply -k samples/asm-istiod-15/fortioasm15
```

# Install Traffic Director support

To add Traffic Director and Managed networking, some manual preparation is needed.
Before running it, you must perform the project and cluster setup. 

```
export PROJECT_ID=...
export CLUSTER_NAME=asm-free-trial-15
export LOCATION=us-west1-b 

./samples/asm-istiod-15/infrastructure_configs.sh
```


