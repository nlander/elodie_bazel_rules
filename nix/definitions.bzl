def _nix_repo_impl(ctx):
    workspace_root = ctx.path(Label("//:BUILD.bazel")).dirname
    ctx.watch(ctx.path(Label("//:flake.nix")))
    ctx.watch(ctx.path(Label("//:flake.lock")))
    res = ctx.execute(
        ["nix", "build", ".#" + ctx.attr.flake_output, "--no-link", "--print-out-paths"],
        timeout = 3600,
        working_directory = str(workspace_root),
    )
    if res.return_code != 0:
        fail("failed to fetch {flake_output} via nix build: {build_error}".format(
            flake_output = ctx.attr.flake_output,
            build_error = res.stderr,
        ))
    store_path = res.stdout.strip()
    ctx.symlink(store_path + "/bin", "bin")
    if ctx.attr.has_lib:
        ctx.symlink(store_path + "/lib", "lib")
    bin_files = ctx.path(store_path + "/bin").readdir()
    filegroup_rules = []
    for f in bin_files:
        name = f.basename
        filegroup_rules.append("""
filegroup(
      name = "{name}",
      srcs = ["bin/{name}"],
      visibility = ["//visibility:public"],
)
""".format(name = name))
    ctx.file("BUILD.bazel", "\n".join(filegroup_rules))

nix_repo = repository_rule(
    implementation = _nix_repo_impl,
    local = True,
    attrs = {
        "flake_output": attr.string(mandatory = True),
        "has_lib": attr.bool(default = False),
    },
)

def _nix_toolchain_extension_impl(ctx):
    nix_repo(name = "nix_ghc", flake_output = "ghc-env", has_lib = True)
    nix_repo(name = "nix_xlsx2csv", flake_output = "xlsx2csv")

nix_toolchain_extension = module_extension(
    implementation = _nix_toolchain_extension_impl,
)
