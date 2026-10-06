def _haskell_binary_compile(ctx):
    compiled_binary = ctx.actions.declare_file(ctx.label.name + ".bin")
    src_depset = depset(ctx.files.srcs)
    args = ctx.actions.args()
    args.add("-O2")
    args.add("-o", compiled_binary.path)
    args.add_all(src_depset)
    ctx.actions.run(
        inputs = src_depset,
        outputs = [compiled_binary],
        executable = ctx.executable._ghc,
        arguments = [args],
        mnemonic = "GhcCompile",
        progress_message = "Compiling Haskell binary: %s" % ctx.label.name,
    )
    return compiled_binary

def _normalize_runpath(ctx, file):
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    workspace_name = ctx.workspace_name if ctx.workspace_name else "_main"
    return workspace_name + "/" + file.short_path

def _haskell_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name)

    tool_runfiles = []
    tool_dirs = []
    for tool in ctx.files.tools:
        tool_runfiles.append(tool)
        tool_path = _normalize_runpath(ctx, tool)
        tool_dir = tool_path.rsplit("/", 1)[0]
        if tool_dir not in tool_dirs:
            tool_dirs.append(tool_dir)
    path_exports = "\n".join(['export PATH="$RUNFILES_DIR/{dir}:$PATH"'.format(dir=d) for d in tool_dirs])
    common_script_content = """#!/usr/bin/env bash
if [ -z "$RUNFILES_DIR" ]; then
  if [ -d "${{BASH_SOURCE[0]}}.runfiles" ]; then
    RUNFILES_DIR="${{BASH_SOURCE[0]}}.runfiles"
  else
    RUNFILES_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
  fi
fi

{path_exports}
""".format( path_exports = path_exports )
    outputs = [script]
    runfiles_files = list(tool_runfiles)
    if ctx.attr._run_type == "haskell_binary":
        compiled_binary = _haskell_binary_compile(ctx)
        real_binary_runpath = _normalize_runpath(ctx, compiled_binary)
        script_suffix = """
exec "$RUNFILES_DIR/{real_binary}" "$@"
""".format( real_binary = real_binary_runpath )
        outputs.append(compiled_binary)
        runfiles_files.append(compiled_binary)
    elif ctx.attr._run_type == "haskell_repl":
        ghc_runpath = _normalize_runpath(ctx, ctx.executable._ghc)
        src_runpaths = [_normalize_runpath(ctx, src) for src in ctx.files.srcs]
        src_args = " ".join(['"$RUNFILES_DIR/{src}"'.format(src = src) for src in src_runpaths])
        script_suffix = """
exec "$RUNFILES_DIR/{ghc}" --interactive {src_args}
""".format(
            ghc = ghc_runpath,
            src_args = src_args,
        )
        runfiles_files.extend(ctx.files.srcs)
        runfiles_files.append(ctx.executable._ghc)
    else:
        script_suffix = ""

    ctx.actions.write(
        output = script,
        content = common_script_content + script_suffix,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        files = depset(outputs),
        runfiles = ctx.runfiles(files = runfiles_files),
    )]

def _make_haskell_rule(run_type, ghc_cfg):
    return rule(
        implementation = _haskell_impl,
        executable = True,
        attrs = {
            "srcs": attr.label_list(allow_files = [".hs"]),
            "tools": attr.label_list(allow_files = True,
                cfg = "target",
                default = [],
            ),
            "_run_type": attr.string(default = run_type),
            "_ghc": attr.label(
                default = Label("@nix_ghc//:ghc"),
                executable = True,
                cfg = ghc_cfg,
            ),
        },
    )

haskell_repl = _make_haskell_rule("haskell_repl", "target")
haskell_binary = _make_haskell_rule("haskell_binary", "exec")
