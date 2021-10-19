x_help_subcommand() {
  x_usage
}

x_usage() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} experimental [SUBCOMMAND] [OPTION]...

Use features/services in beta or preview states. Can also be accessed using
'x' as a short version of 'experimental'.

SUBCOMMANDS:
  install                             Install using a Google backend service
                                      instead of client-side tools
  vm                                  Functions to configure a mesh to
                                      allow external VM workloads.
  mcp-migrate-check                   Checks IstioOperator config for
                                      compatibility with a Google managed
                                      control plane and generates new config
                                      where possible.

FLAGS:

  --use_vpcsc                         Install Google-managed control plane in
                                      a VPC Service Control restricted
                                      environment.
EOF
}
