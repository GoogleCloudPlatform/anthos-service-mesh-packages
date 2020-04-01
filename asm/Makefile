# Copyright 2020 Google Inc. All Rights Reserved.

all: istio-15 roles crd

.PHONY: check-env check-istio check-helm
check-env: check-istio check-helm

check-istio:
ifndef ISTIO_SRC
		$(error ISTIO_SRC is undefined, should be directory to istio/istio sources)
endif

check-helm:
ifeq (,$(shell which helm))
		$(error a helm v2 binary must be in your PATH)
endif
ifeq (,$(shell bash -c "helm version -c | grep 'v2'"))
		$(error only helm v2 is supported)
endif

.PHONY: istio-15 roles crd 
istio-15: cluster/istio-15.yaml
roles: cluster/roles.yaml
crd: cluster/crd-all.gen.yaml

cluster/istio-15.yaml: check-env
	helm template --name asm-istio --namespace=istio-system \
		$(ISTIO_SRC)/manifests/istio-control/istio-discovery \
		-f $(ISTIO_SRC)/manifests/global.yaml \
		--set clusterResources=false \
		--set revision=asm15 \
		--set global.useMCP=false > oss-istio-15/istio-1.5.yaml

cluster/roles.yaml: check-env
	helm template --name asm-istio --namespace=istio-system \
		$(ISTIO_SRC)/manifests/istio-control/istio-discovery \
		-f $(ISTIO_SRC)/manifests/global.yaml \
		--set clusterResrouces=true \
		--set global.operatorManageWebhooks=true \
		--set global.useMCP=true \
		--set revision=asm15 > cluster/roles.yaml
#sed -e "s/#.*$$//g" -i cluster/roles.yaml
#sed -e "/^[[:space:]]*$$/d" -i cluster/roles.yaml

cluster/crd-all.gen.yaml: check-env
	cp $(ISTIO_SRC)/manifests/base/files/crd-all.gen.yaml cluster/crd-all.gen.yaml
