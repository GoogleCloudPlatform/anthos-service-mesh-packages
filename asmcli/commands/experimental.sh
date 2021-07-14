experimental_subcommand() {
  case "${1}" in
    vm)
      shift 1
      vm_subcommand "${@}"
      ;;
    *)
      x_help_subcommand "${@}"
      ;;
  esac
}
