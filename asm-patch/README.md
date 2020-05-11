# Anthos Service Mesh patch package

The asm-patch package contains [kustomize](https://github.com/kubernetes-sigs/kustomize) configurations to enable ASM feature on an existing cluster.
It includes a root kustomization.yaml file, a patch folder for cluster and nodepool patches, and additional resources.
In additional to the existing kpt config setters (e.g. gcloud.container.cluster, gcloud.core.project, and etc.), it adds a new one, base-dir, which sets the base directory of the configurations of an existing cluster.

## Instructions on how to apply the patches

1. Set up your environment
   ```bash
   export PROJECT_ID=YOUR_PROJECT_ID
   export BASE_DIR=YOUR_BASE_DIR
   export CLUSTER_NAME=YOUR_CLUSTER_NAME
   ```

2. Prepare the resource configurations of an existing cluster in the `${BASE_DIR}` directory
   - If the resource configurations are ready, put them under `${BASE_DIR}`
   - If the resource configurations are not available, export using anthoscli export:
     ```bash
     anthoscli export -c ${CLUSTER_NAME} -o ${BASE_DIR}
     ```

3. Download the patch package to the current working directory:
   `kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/asm-patch@existing-cluster .`
   By default, the kpt pkg get command populates the compute zone in the package files to match your current configuration.

4. List available configuration setters in this package: `kpt cfg list-setters asm-patch`

   Output looks like this:
   
    | NAME                         | DESCRIPTION | VALUE               | TYPE   | COUNT | SETBY |
    |------------------------------|-------------|---------------------|--------|-------|-------|
    | base-dir                     | ''          | ../your-cluster     | string | 1     |       |
    | gcloud.container.cluster     | ''          | your-cluster        | string | 5     |       |
    | gcloud.compute.location      | ''          | us-central1-c       | string | 3     | kpt   |
    | gcloud.core.project          | ''          | your-project        | string | 15    | kpt   |
    | gcloud.project.projectNumber | ''          | your-project-number | string | 3     | kpt   |



5. (Optional) Customize the configuration via setters:
   ```bash
   # The cluster name must contain only lowercase alphanumerics and '-', must start with a letter and end with an alphanumeric, and must be no longer than 40 characters.
   kpt cfg set asm-patch [SETTER_NAME] [SETTER_VALUE]
   # For example, `kpt cfg set asm-patch gcloud.container.cluster [YOUR_CLUSTER_NAME]`
   ```

6. Apply the Anthos Service Mesh patches on the existing cluster:
   ```bash
   pushd ${BASE_DIR} && kustomize create --autodetect --namespace ${PROJECT_ID} && popd
   kustomize create --resources asm-patch && kustomize build -o ${BASE_DIR}/all.yaml
   ```

7. (Optional) Before applying the ASM patches, you can check in the current configuration to a git repo. 
It will enable you to check the changes via `git diff` after applying the patch to the same ${BASE_DIR}.

