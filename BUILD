package(default_visibility = ["//visibility:public"])

ALL_MODULES = glob(["asmcli/**/*.sh"], exclude = ["**/test*/**"],)
MERGE_OUT = ["asmcli"]

genrule(
    name = "merge",
    srcs = ALL_MODULES,
    outs = MERGE_OUT,
    cmd = "$(location scripts/release-asm/merge) $(OUTS) $(SRCS)",
    tools = ["scripts/release-asm/merge"],
    executable = True,
)