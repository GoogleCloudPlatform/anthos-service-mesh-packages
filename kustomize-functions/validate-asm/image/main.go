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

	"sigs.k8s.io/kustomize/kyaml/kio"
	"sigs.k8s.io/kustomize/kyaml/kio/kioutil"
	"sigs.k8s.io/kustomize/kyaml/yaml"
)

const (
	loggingServiceValue    = "logging.googleapis.com/kubernetes"
	monitoringServiceValue = "monitoring.googleapis.com/kubernetes"
	containerClusterKind   = "ContainerCluster"
	containerNodePoolKind  = "ContainerNodePool"
	apiGroup               = "container.cnrm.cloud.google.com"
)

var supportedReleaseChannels = []string{"REGULAR", "RAPID", "STABLE"}
var n1CustomMachineTypeRegex = regexp.MustCompile(`(\w+)-(\d+)-(\d+)`)
var customMachineTypeRegex = regexp.MustCompile(`(\w+)-(\w+)-(\d+)-(\d+)`)
var machineTypeRegex = regexp.MustCompile(`(\w+)-(\w+)-(\d+)`)
var valueWithComment = regexp.MustCompile(`\s*(\S+)(\s+#.*)?`)

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

type Severity int

func (s Severity) String() string {
	severities := [...]string {
		"Warning",
		"Error",
	}
	return severities[s]
}

const (
	Warning Severity = iota
	Error
)

type ValidationError struct {
	severity Severity
	err error
}

func (e ValidationError) Error() string {
	return fmt.Sprintf("%s - %s", e.severity, e.err.Error())
}

type ValidationErrors struct {
	errors []error
	warnings []error
}

func (e ValidationErrors) Error() string {
	warnings := make([]string, len(e.warnings))
	errors := make([]string, len(e.errors))
	for i, w := range e.warnings {
		warnings[i] = fmt.Sprintf("* %s", w)
	}
	for i, e := range e.errors {
		errors[i] = fmt.Sprintf("* %s", e)
	}
	if len(warnings) == 0 && len(errors) == 0 {
		return fmt.Sprintf("no warnings/errors occurred")
	}
	if len(warnings) == 0 {
		return fmt.Sprintf("%d error(s) occurred:\n\t%s\n\n",
			len(errors), strings.Join(errors, "\n\t"))
	}
	if len(errors) == 0 {
		return fmt.Sprintf("%d warning(s) occurred:\n\t%s\n\n",
			len(warnings), strings.Join(warnings, "\n\t"))
	}
	return fmt.Sprintf("%d warning(s) occurred:\n\t%s\n\n%d error(s) occurred:\n\t%s\n\n",
		len(warnings), strings.Join(warnings, "\n\t"),
		len(errors), strings.Join(errors, "\n\t"))
}

// Filter injects new filters into container cluster and nodepool.
func (filter) Filter(in []*yaml.RNode) ([]*yaml.RNode, error) {
	var errList []error
	var warningList []error

	for _, r := range in {
		if errs := validate(r); len(errs) != 0 {
			for _, e := range errs {
				if e.severity == Warning {
					warningList = append(warningList, e)
				} else {
					errList = append(errList, e)
				}
			}
		}
	}
	if len(errList) == 0 && len(warningList) == 0 {
		return nil, nil
	}
	return nil, ValidationErrors{errors: errList, warnings: warningList}
}

// https://cloud.google.com/service-mesh/docs/gke-install-existing-cluster#setting_up_your_project
func validate(r *yaml.RNode) []ValidationError {

	var errList []ValidationError

	meta, err := r.GetMeta()
	if err != nil {
		errList = append(errList, ValidationError{Error, err})
		return errList
	}

	if strings.HasPrefix(meta.ApiVersion, apiGroup) && meta.Kind == containerClusterKind {

		// validate if Cloud Monitoring and Logging are enabled
		if err := validateNodeValue(r, meta, loggingServiceValue, "spec", "loggingService"); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}
		if err := validateNodeValue(r, meta, monitoringServiceValue, "spec", "monitoringService"); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}

		// validate if Workload Identity is enabled
		if _, err := validateNodeExists(r, meta, "spec", "workloadIdentity", "identityNamespace"); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}

		// validate if mesh_id label is set
		if _, err := validateNodeExists(r, meta, "spec", "labels", "mesh_id"); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}

		// validate release channel
		if err := validateReleaseChannel(r, meta, supportedReleaseChannels, "spec", "releaseChannel", "channel"); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}

		// validate machine type
		if err := validateMachineType(r, meta, false); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}
	}

	if strings.HasPrefix(meta.ApiVersion, apiGroup) && meta.Kind == containerNodePoolKind {
		if err := validateNodeCountAtLeast(r, meta, 4, "ASM requires at least four nodes. If you need to add nodes, see https://bit.ly/2RnVL2T"); err != nil {
			errList = append(errList, ValidationError{Warning, err})
		}

		// validate machine type
		if err := validateMachineType(r, meta, true); err != nil {
			errList = append(errList, ValidationError{Error, err})
		}
	}
	return errList
}

func validateNodeValue(r *yaml.RNode, meta yaml.ResourceMeta, expected string, path ...string) error {
	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return err
	}
	pathString := strings.Join(path, ".")
	value, err := stripValueComment(node, r, meta, pathString)
	if err != nil {
		return err
	}

	if value != expected {
		return fmt.Errorf(
			"unsupported %s value in %s %s (%s [%s]), expected: %s, actual: %s",
			pathString, meta.Kind, meta.Name,
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

func stripValueComment(node *yaml.RNode, r *yaml.RNode, meta yaml.ResourceMeta, path string) (string, error) {
	value, err := node.String()
	if err != nil {
		s, _ := r.String()
		return "", fmt.Errorf("%v: %s", err, s)
	}
	group := valueWithComment.FindStringSubmatch(value)
	if len(group) < 3 {
		return "", fmt.Errorf("unknown format of %s: %s in %s %s (%s [%s])",
			path, value, meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation])
	}
	return group[1], nil
}

func contains(s []string, e string) bool {
	for _, a := range s {
		if a == e {
			return true
		}
	}
	return false
}

func validateNodeCountAtLeast(r *yaml.RNode, meta yaml.ResourceMeta, min int, errorInfo string) error {
	nodeCountAbsent, err := nodeAbsentOrAtLeast(r, meta, min, errorInfo, "spec", "nodeCount")
	if nodeCountAbsent {
		if _, err := nodeAbsentOrAtLeast(r, meta, min, errorInfo, "spec", "initialNodeCount"); err != nil {
			return err
		}

	} else if err != nil {
		return err
	}
	return nil
}

func nodeAbsentOrAtLeast(r *yaml.RNode, meta yaml.ResourceMeta, min int, errorInfo string, path ...string) (absent bool, err error) {
	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return true, err
	}

	pathString := strings.Join(path, ".")
	value, err := stripValueComment(node, r, meta, pathString)
	if err != nil {
		return false, err
	}
	count, err := strconv.Atoi(value)
	if err != nil {
		s, _ := r.String()
		return false, fmt.Errorf("%v: %s", err, s)
	}
	if count < min {
		return false, fmt.Errorf(
			"%s is %d in %s %s (%s [%s]). %s",
			pathString, count, meta.Kind, meta.Name,
			meta.Annotations[kioutil.PathAnnotation],
			meta.Annotations[kioutil.IndexAnnotation],
			errorInfo)
	}
	return false, nil
}

func validateReleaseChannel(r *yaml.RNode, meta yaml.ResourceMeta, expected []string, path ...string) error {

	node, err := validateNodeExists(r, meta, path...)
	if err != nil {
		return err
	}
	pathString := strings.Join(path, ".")
	value, err := stripValueComment(node, r, meta, pathString)
	if err != nil {
		return err
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

func validateMachineType(r *yaml.RNode, meta yaml.ResourceMeta, mustExist bool) error {
	node, err := validateNodeExists(r, meta, "spec", "nodeConfig", "machineType")
	if err != nil {
		if mustExist {
			return err
		} else {
			return nil
		}
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
