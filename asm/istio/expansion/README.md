# Anthos Service Mesh Expansion

There are currently a few files in this directory that supports expansion to the
mesh.

- `gen-eastwest-gateway.sh` can be used to generate a custom `IstioOperator`
configuration for the expansion gateway deployment. Please refer to the current
Anthos Service Mesh [user guide](https://cloud.google.com/service-mesh/docs/gke-on-prem-install-multicluster-vmware)
on how to use the script.

- `vm-eastwest-gateway.yaml` is a generated `IstioOperator` configuration for
the expansion gateway deployment to be used when adding VM workloads on the same
network to the mesh. Don't use this configuration as an overlay when installing
any other ASM components. This is only to add the expansion gateway to an
existing installation.

- `expose-istiod.yaml` is used to expose the control plane for discovery from
workloads outside of the cluster.

- `expose-services.yaml` can be used to allow services on different networks in
the same mesh to communicate with each other.
