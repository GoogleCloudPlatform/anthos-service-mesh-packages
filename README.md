# Anthos Service Mesh packages

This repository contains packaged configuration for setting up a GKE cluster
with [Anthos Service Mesh] features enabled.

## Setup

1.  In order to use a packages, you need to install [gcloud].
2.  Afterwards, install three components:

    ```bash
    $ gcloud components install kpt anthoscli alpha
    ```
3.  Fetch the package:

    ```bash
    # [PACKAGE] is any directory name under the repository root.
    # [OUTPUT_DIR] refers to the desired local location of the package.
    $ kpt pkg get
    https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages.git/[PACKAGE] [OUTPUT_DIR]
    ```
4.  Verify all configurable values are as desired:

    ```bash
    $ kpt cfg list-setters [OUTPUT_DIR]
    # If any values aren't what you want, run something like below:
    $ kpt cfg set [OUTPUT_DIR] [NAME] [VALUE]
    ```
5.  Deploy the package:

    ```bash
    $ gcloud alpha anthos apply [OUTPUT_DIR]
    ```

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/
[gcloud]: https://cloud.google.com/sdk/gcloud/
