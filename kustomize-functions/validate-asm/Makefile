# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.PHONY: generate license fix vet fmt test build tidy image

GOBIN := $(shell go env GOPATH)/bin

build:
	(cd image && go build -v -o $(GOBIN)/config-function .)

all: generate license build fix vet fmt test lint tidy

fix:
	(cd image && go fix ./...)

fmt:
	(cd image && go fmt ./...)

generate:
	(which $(GOBIN)/mdtogo || go get sigs.k8s.io/kustomize/cmd/mdtogo)
	(cd image && GOBIN=$(GOBIN) go generate ./...)

license:
	(which $(GOPATH)/bin/addlicense || go get github.com/google/addlicense)
	$(GOPATH)/bin/addlicense  -y 2020 -c "Google LLC" -f LICENSE_TEMPLATE .

tidy:
	(cd image && go mod tidy)

lint:
	(which $(GOBIN)/golangci-lint || go get github.com/golangci/golangci-lint/cmd/golangci-lint@v1.19.1)
	(cd image && $(GOBIN)/golangci-lint run ./...)

test:
	(cd image && go test -cover ./...)

vet:
	(cd image && go vet ./...)

image:
	docker build image -t gcr.io/kustomize-functions/validate-asm:v0.1.0
	docker push gcr.io/kustomize-functions/validate-asm:v0.1.0
