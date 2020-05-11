# Injection

This is a function to validate Anthos Service Mesh features on clusters

It is written in `go` and uses the `kyaml` libraries for parsing the
input and writing the output.  Writing in `go` is not a requirement.

## Function implementation

The function is implemented as an [image](image), and built using `make image`.

The template is implemented as a go program, which reads a collection of input
Resource configuration, and looks for invalid configuration.

## Function invocation

The function is invoked by authoring a [local Resource](local-resource)
with `metadata.annotations.[config.kubernetes.io/function]` and running:

    kustomize config run local-resource/

This exits non-zero if there is an error.

## Running the Example

Run the validator with:

    kustomize config run local-resource/

This will include the following features per https://bit.ly/39VFQze:
1. validate if the cluster's master node version is supported
2. validate if the cluster's machine type meets the minimal requirement
3. validate if Cloud Monitoring and Logging are enabled
4. validate if Workload Identity is enabled
5. validate if mesh_id label is set
6. validate if using a release channel rather than a static version of GKE
7. validate if the cluster has at least four nodes
