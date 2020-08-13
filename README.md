# Anthos Service Mesh packages

This repository contains packaged configuration for setting up a GKE cluster
with [Anthos Service Mesh] features enabled.

[Anthos Service Mesh]: https://cloud.google.com/anthos/service-mesh/

Package Descriptions:

* `asm`: Creates an ASM ready cluster and installs ASM
* `asm-multiproject`: Creates an ASM ready cluster and installs ASM for a multiproject mesh
* `asm-patch`: Exports an existing cluster to config, updates that cluster to
  support ASM requirements, and installs ASM
* `asm-multiproject-patch`: Exports an existing cluster to config, updates that cluster to
  support ASM requirements, and installs ASM for a multiproject mesh