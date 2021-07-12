experimental_subcommand() {
  if [[ "${*}" = '' ]]; then
    x_usage >&2
    exit 2
  fi

  case "${1}" in
    vm)
      shift 1
      vm_subcommand "${@}"
      ;;
    install)
      shift 1
      x_install_subcommand "${@}"
      ;;
    *)
      x_help_subcommand "${@}"
      ;;
  esac
}
