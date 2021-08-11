# Attach VM to Anthos Service Mesh 

Note: this feature is not available for public use.

Adding vSphere VMs to Anthos Service Mesh includes three steps:
- Create attach context.
- Set current context.
- Attach individual VMs.

This script has the following dependencies:
- kubectl
- jq
- printf
- sed


## Create Attach Context

Admin creates a couple of “attach_contexts”. Each “attach_context” includes common properties for a group of VMs. 
Options specified via flags take precedence over environment Variables. 

| Flag option       | Variable     | Description (default value)     |
| :------------- | :----------: | :-----------: |
| -key | KEY_FILE | SSH key file to access the VMs. This is a required argument. |
| -ns | VM_NAMESPACE | VM namespace ( “default”) |
| -sa | SERVICE_ACCOUNT | VM service account (“default”) |
| -labels | LABELS | VM WorkloadGroup metadata labels. Input pattern is like “key:value; key1:value1”. You can try with “version:latest; channel:stable” Space in the string will be ignored. There should be no quotes in the label. |
| -net | VM_NETWORK | VM network (If unspecified, will be set as cluster network and it’s single network scenario. (For multi-network deployment, specify a different network.) |
| -mesh | MESH_ID | VM mesh (“proj-${PROJECT_NUMBER}”) |
| -cluster | CLUSTER | The name of the target cluster to register VM to (for multi-cluster deployment only) |
| -project | PROJECT_ID | The GCP project ID (gcloud config get-value project) |
| -kubeconfig | KUBECONFIG | Absolute path to the kubeconfig file to use for CLI requests which points to a bare metal cluster (“$HOME/.kube/config”) |
| -out | OUTPUT_DIR | Directory to store the VM configuration files (WORK_DIR). |
| -vmdir | VM_DIR | Directory on VM to temporarily store the VM configuration files (“/tmp”). |


## Set Context
   
Admin runs set_context CONTEXT_NAME to set the current “attach_context”. After setting the context, all following attaching VMs will use this context by default. 
All created contexts are stored as a file .CONTEXT_NAME under the working directory. 


## Attach VM
   
Run “attach_vm” to attach a group of VMs that share the same context. Any property in “attach_context”. 
All other configs for creat_attach_context can be used to override settings on the current context.
   
| Flag option       | Variable     | Description (default value)     |
| :------------- | :----------: | :-----------: |
|  -app | VM_APP   | VM app name. This is a required argument.   |
| -addr   | VM_IP | VM IP address or DNS name. This is a required argument. |
| -context | SELECT_CONTEXT | Attach context (current set context) |

“attach_vm” script does the following:
- Register the VM to ASM control plane.
- Extract VM configuration from the environment (meshconfig, VM registry, gateway IP, CA root certificate, etc), request a bootstrap Kubernetes token, and place all configuration to a folder.
- Copy configuration (cluster.env, istio-token, mesh.yaml, root-cert.pem, hosts) to a VM.
- SSH to the VM and install istio sidecar on the VM.
- Start Istio within the virtual machine.
