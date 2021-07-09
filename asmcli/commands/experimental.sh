experimental_subcommand() {
  case "${1}" in
    *)
      x_help_subcommand "${@}"
      ;;
  esac
}
