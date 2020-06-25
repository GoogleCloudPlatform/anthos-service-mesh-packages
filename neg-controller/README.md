# NEG Controller

This is the l7-load-balancer controller
(https://github.com/kubernetes/ingress-gce), deployed in the GKE master nodes as
the `http load balancer` addon. At the moment, the version in GKE stable does
not have support for the ASM Managed Control Plane extensions. Until they are
deployed, this set of resources is required.
