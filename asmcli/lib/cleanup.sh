cleanup() {
  relocate_log_file
}

relocate_log_file() {
    local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"
    local NEW_LOG_FILE_PATH; NEW_LOG_FILE_PATH="${OUTPUT_DIR}/logs.txt"

    if [[ ! -f $LOG_FILE_PATH ]]
    then
        return 0
    fi

    # Relocate the log file to the working directory.
    mv $LOG_FILE_PATH $NEW_LOG_FILE_PATH
}
