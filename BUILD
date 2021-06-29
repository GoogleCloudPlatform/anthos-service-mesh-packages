package(default_visibility = ["//visibility:public"])

ASMCLI_MODULES = glob(["asmcli/**"])
NODE_MODULES = glob(["node_modules/**"])
ASMCLI_SOURCES = glob(["asmcli/**/*.sh"], exclude = ["**/test*/**"],)
TESTS = glob(["asmcli/tests/**/*.bats"])
MERGE_OUT = ["asmcli"]
BATS_JOBS = "7" # determined emperically

genrule(
    name = "merge",
    srcs = ASMCLI_SOURCES,
    outs = MERGE_OUT,
    cmd = "$(location scripts/release-asm/merge) $(OUTS) $(SRCS)",
    tools = ["scripts/release-asm/merge"],
    executable = True,
)

sh_library(
    name = "asmcli_modules",
    data = ASMCLI_MODULES,
)

sh_library(
    name = "node_modules",
    data = NODE_MODULES,
)

sh_test(
    name = "test",
    size = "large",
    srcs = ["node_modules/bats/bin/bats"],
    deps = [
            ":asmcli_modules",
            ":node_modules",
            ],
    env = {"SOURCE_FILES": '\n'.join(ASMCLI_SOURCES)},
    args = TESTS + ["--jobs", BATS_JOBS, "--no-parallelize-across-files"],
)

sh_test(
    name = "lint_variables",
    srcs = ["asmcli/tests/lint_variables"],
    deps = [
        ":asmcli_modules",
    ],
    args = ["asmcli/asmcli"] + ASMCLI_SOURCES
)
