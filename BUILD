package(default_visibility = ["//visibility:public"])
load(":merge.bzl", "merge")

merge(
    name = "merge",
    out = "asmcli",
    chunks = glob(
        ["asmcli/**/*.sh"],
        exclude = ["**/test*/**"],  # exclude any directory that starts with test
    ),
    merge_tool = "//:merge_script"
)

sh_binary(
    name = "merge_script",
    srcs = ["scripts/release-asm/merge"],
)
