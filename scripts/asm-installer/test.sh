function create_workloads() {
    local ctxzero="${1}"
    local ctxone="${2:-debian-10}"
    local ctxtwo="${3:-debian-cloud}"
    local ctxthree="${4}"
    echo $ctxzero
    echo $ctxone
    echo $ctxtwo
    echo $ctxthree
}

create_workloads