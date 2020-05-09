// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package main implements an injection function for resource reservations and
// is run with `kustomize config run -- DIR/`.
package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	multierr "github.com/hashicorp/go-multierror"
	"sigs.k8s.io/kustomize/kyaml/kio"
	"sigs.k8s.io/kustomize/kyaml/kio/kioutil"
	"sigs.k8s.io/kustomize/kyaml/yaml"
)

const (
	loggingServiceValue    = "logging.googleapis.com/kubernetes"
	monitoringServiceValue = "monitoring.googleapis.com/kubernetes"
	containerClusterwKind   = "ContainerCluster"
	containerNodePoolKind  = "ContainerNodePool"
	apiGroup               = "container.cnrm.cloud.google.com"
)

var supportedReleaseChannels = []string{"REGULAR", "RAPID", "STABLE"}
var nodeVersionRegex = regexp.MustCompile(`(\d+).(\d+).(\d+)-gke.(\d+)`)
var n1CustomMachineTypeRegex = regexp.MustCompile(`(\w+)-(\d+)-(\d+)`)
var customMachineTypeRegex = regexp.MustCompile(`(\w+)-(\w+)-(\d+)-(\d+)`)
var machineTypeRegex = regexp.MustCompile(`(\w+)-(\w+)-(\d+)`)

func main() {
	rw := &kio.ByteReadWriter{Reader: os.Stdin, Writer: os.Stdout, KeepReaderAnnotations: true}
	p := kio.Pipeline{
		Inputs:  []kio.Reader{rw},       // read the inputs into a slice
		Filters: []kio.Filter{filter{}}, // run the enableASM into the inputs
		Outputs: []kio.Writer{rw}}       // copy the inputs to the output
	if err := p.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
}

// filter implements kio.Filter
type filter struct{}

// Filter injects new filters into container cluster and nodepool.
func (filter) Filter(in []*yaml.RNode) ([]*yaml.RNode, error) {
	var errList []error

	for _, r := range in {
		if errs := validate(r); len(errs) != 0 {
			errList = append(errList, errs...)
		}
	}
	if errs := multierr.Append(nil, errList...); errs != nil {
		return nil, errs
	}
	return in, nil
}

// https://cloud.google.com/service-mesh/docs/gke-install-existing-cluster#setting_up_your_project
func validate(r *yaml.RNode) []error {

	var errList []error

	meta, err := r.GetMeta()
	if err != nil {
		errList = append(errList, err)
		return errList
	}

	if strings.HasPrefix(meta.ApiVersion, apiGroup) && meta.Kind == containerClusterKind {

		// validate if Cloud Monitoring and Logging are enabled
		if err := validateNodeValue(r, meta, loggingServiceValue, "spec", "loggingService"); err != nil {
			errList = append(errList, err)
		}
		if err := validateNodeValue(r, meta, monitoringServiceValue, "spec", "monitoringService"); err != nil {
			errList = append(errList, err)
		}

		// validate if Workload Identity is enabled
		if _, err := validateNodeExists(r, meta, "spec", "workloadIdentity", "identityNamespace"); err != nil {
			errList = append(errList, err)
		}

		// validate if mesh_id lable is set
		if _, err := validateNodeExists(r, meta, "spec", "labels", "mesh_id"); err != nil {
			errList = append(errList, err)
		}

		// validate release channel
		if err := validateNodeValueIn(r, meta, supportedReleaseChannels, "spec", "releaseChannel", "channel"); err != nil {
			errList = append(errList, err)
		}

		// validate master node version
		if err := validateMasterNodeVersion(r, meta); err != nil {
			errList = append(errList, err)
		}

		// validate machine type
		if err := validateMachineType(r, meta); err != nil {
			errList = append(errList, err)
		}
	}

	if strings.HasPrefix(meta.ApiVersion, apiGroup) && meta.Kind == containerNodePoolKind {
		if err := validateNodeValueGreaterThan(r, meta, 3, "ASM requires at least four nodes. If you need to add nodes, see https://bit.ly/2RnVL2T", "spec", "nodeCount"); err != nil {
			errList = append(errList, err)
		}

		// validate machine type
		if err := validateMachineType(r, meta); err != nil {
			errList = append(errList, err)
		}
	}
	return errList
}

func validateNodeValue(r *yaml.RNode, meta yaml.ResourceMeta, expected string, path ...string) error {
	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return err
	}
	value, err := node.String()
	value = strings.TrimSpace(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	if value != expected {
		return fmt.Errorf(
			"unsupported %s value in %s %s (%s [%s]), expected: %s, actual: %s",
			strings.Join(path, "."),
			meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation],
			expected,
			value)
	}
	return nil
}

func validateNodeExists(r *yaml.RNode, meta yaml.ResourceMeta, path ...string) (*yaml.RNode, error) {
	node, err := r.Pipe(yaml.Lookup(path...))
	if err != nil {
		s, _ := r.String()
		return nil, fmt.Errorf("%v: %s", err, s)
	}
	if node == nil {
		return node, fmt.Errorf(
			"%s missing in %s %s (%s [%s])",
			strings.Join(path, "."),
			meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation])
	}
	return node, nil
}

func validateNodeValueIn(r *yaml.RNode, meta yaml.ResourceMeta, expected []string, path ...string) error {
	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return err
	}
	value, err := node.String()
	value = strings.TrimSpace(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}

	if contains(expected, value) {
		return nil
	}
	return fmt.Errorf(
		"unsupported %s value in %s %s (%s [%s]), expected: %s, actual: %s",
		strings.Join(path, "."),
		meta.Kind, meta.Name,
		meta.Annotations[kioutil.PathAnnotation],
		meta.Annotations[kioutil.IndexAnnotation],
		strings.Join(expected, ","),
		value)
}

func contains(s []string, e string) bool {
	for _, a := range s {
		if a == e {
			return true
		}
	}
	return false
}

func validateNodeValueGreaterThan(r *yaml.RNode, meta yaml.ResourceMeta, min int, errorInfo string, path ...string) error {
	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return err
	}
	value, err := node.String()
	value = strings.TrimSpace(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	count, err := strconv.Atoi(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	if count <= min {
		return fmt.Errorf(
			"%s is %d in %s %s (%s [%s]). %s",
			strings.Join(path, "."),
			count,
			meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation],
			errorInfo)
	}
	return nil
}

func validateMasterNodeVersion(r *yaml.RNode, meta yaml.ResourceMeta) error {
	node, err := validateNodeExists(r, meta, "status", "masterVersion")
	if err != nil {
		return err
	}
	value, err := node.String()
	value = strings.TrimSpace(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}

	version := nodeVersionRegex.FindStringSubmatch(value)
	if len(version) < 5 {
		return fmt.Errorf("unknown masterVersion format: %s in %s %s (%s [%s])",
			value, meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation])
	}

	g2, err := strconv.Atoi(version[2])
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	g3, err := strconv.Atoi(version[3])
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	g4, err := strconv.Atoi(version[4])
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}

	switch g2 {
	case 13:
		if g3 < 11 || (g3 == 11 && g4 < 14) {
			return unsupportedGKEVersionError(value, meta)
		}
	case 14:
		if g3 < 8 || (g3 == 8 && g4 < 18) {
			return unsupportedGKEVersionError(value, meta)
		}
	case 15:
		if g3 < 4 || (g3 == 4 && g4 < 15) {
			return unsupportedGKEVersionError(value, meta)
		}
	default:
		return unsupportedGKEVersionError(value, meta)
	}
	return nil

}

func validateMachineType(r *yaml.RNode, meta yaml.ResourceMeta) error {
	node, err := validateNodeExists(r, meta, "spec", "nodeConfig", "machineType")
	if err != nil {
		return err
	}
	value, err := node.String()
	value = strings.TrimSpace(value)
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}

	// n1 custom
	if strings.HasPrefix(value, "custom") {
		if err := validateCustomMachineType(r, meta, n1CustomMachineTypeRegex, value, 4, 2); err != nil {
			return err
		}
	} else if strings.Contains(value, "custom") { // n2, e2 custom
		if err := validateCustomMachineType(r, meta, customMachineTypeRegex, value, 5, 3); err != nil {
			return err
		}
	} else if strings.Contains(value, "micro") || strings.Contains(value, "small") || strings.Contains(value, "medium") {
		return unsupportedMachineTypeError(value, meta)
	} else {
		if err := validateCustomMachineType(r, meta, machineTypeRegex, value, 4, 3); err != nil {
			return err
		}
	}

	return nil
}

func validateCustomMachineType(r *yaml.RNode, meta yaml.ResourceMeta, reg *regexp.Regexp, value string, groupLen, vcpuIndex int) error {
	machineType := reg.FindStringSubmatch(value)
	if len(machineType) < groupLen {
		return fmt.Errorf("invalid machineType format: %s in %s %s (%s [%s])", value, meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation])
	}

	vcpu, err := strconv.Atoi(machineType[vcpuIndex])
	if err != nil {
		s, _ := r.String()
		return fmt.Errorf("%v: %s", err, s)
	}
	if vcpu < 4 {
		return unsupportedMachineTypeError(value, meta)
	}
	return nil
}

func unsupportedMachineTypeError(value string, meta yaml.ResourceMeta) error {
	return fmt.Errorf("unsupported machine type: %s in %s %s (%s [%s]). The minimum machine type is n1-standard-4, "+
		"which has four vCPUs. If the machine type for your cluster doesn't have at least four vCPUs, "+
		"change the machine type as described here https://bit.ly/2V0KPdu", value, meta.Kind, meta.Name,
		meta.Annotations[kioutil.PathAnnotation],
		meta.Annotations[kioutil.IndexAnnotation])
}

func unsupportedGKEVersionError(version string, meta yaml.ResourceMeta) error {
	return fmt.Errorf("unsupported GKE version %s in %s %s (%s [%s]). If you need to upgrade "+
		"your cluster to a supported version (https://bit.ly/2XsilLq), see https://bit.ly/34vygKy",
		version, meta.Kind, meta.Name,
		meta.Annotations[kioutil.PathAnnotation],
		meta.Annotations[kioutil.IndexAnnotation])
}
