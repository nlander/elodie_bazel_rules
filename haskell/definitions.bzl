HaskellLibraryInfo = provider(
    doc = "Información de una librería de Haskell compilada",
    fields = ["pkg_dir", "pkg_name", "modules", "dependencies"],
)

PACKAGE_VERSION = "0.1.0"

def _haskell_compile_common_args(ctx, args, all_deps):
    dep_dirs = []
    src_depset = depset(ctx.files.srcs)
    all_inputs = list(ctx.files.srcs)
    args.add("-O2")
    if ctx.attr.deps:
        for dep in ctx.attr.deps:
            dep_dir = dep[HaskellLibraryInfo].pkg_dir
            args.add("-package-db", dep_dir)
            args.add("-package", dep[HaskellLibraryInfo].pkg_name)
            all_inputs.append(dep_dir)
            dep_id = "{package_name}-{package_version}".format(
                package_name = dep[HaskellLibraryInfo].pkg_name,
                package_version = PACKAGE_VERSION
            )
            all_deps.append(dep_id)
    args.add_all(src_depset)
    return all_inputs, all_deps

def _haskell_binary_compile(ctx):
    compiled_binary = ctx.actions.declare_file(ctx.label.name + ".bin")
    args = ctx.actions.args()
    all_inputs, all_deps = _haskell_compile_common_args(ctx, args)
    args.add("-o", compiled_binary.path)
    ctx.actions.run(
        inputs = depset(all_inputs),
        outputs = [compiled_binary],
        executable = ctx.executable._ghc,
        arguments = [args],
        mnemonic = "GhcCompileBinary",
        progress_message = "Compiling Haskell binary: %s" % ctx.label.name,
    )
    return compiled_binary

def _object_file_from_module(module_name, outputs_dir):
    object_file_path = "{outputs_dir}/{module_location}/{ext}".format(
        outputs_dir = outputs_dir,
        module_location = module_name.replace(".", "/"),
        ext = ".o",
    )
    return object_file_path

def _haskell_library_compile(ctx):
    outputs_dir = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add("-c")
    all_inputs, all_deps = _haskell_compile_common_args(ctx, args, ctx.attr.deps_external)
    args.add("-outputdir", outputs_dir.path)
    ctx.actions.run(
        inputs = depset(all_inputs),
        outputs = [outputs_dir],
        executable = ctx.executable._ghc,
        arguments = [args],
        mnemonic = "GhcCompileLibrary",
        progress_message = "Compiling Haskell library: %s" % ctx.label.name,
    )
    package_name = ctx.label.name.replace("_", "-")
    object_files = [_object_file_from_module(module, outputs_dir) for module in ctx.attr.modules]
    archive_args = ctx.actions.args()
    archive_args.add("rcs")
    archive_name = "{outputs_dir}/lib{pkg_name}.a".format(
        outputs_dir = outputs_dir,
        pkg_name = package_name,
    )
    archive = ctx.actions.declare_file(archive_name)
    archive_args.add(archive_name)
    archive_args.add_all(object_files)
    ctx.actions.run(
        inputs = depset(object_files),
        outputs = [archive],
        executable = ctx.executable._ghc_ar,
        arguments = [archive_args],
        mnemonic = "GhcArLibrary",
        progress_message = "Archiving Haskell library: %s" % ctx.label.name,
    )
    package_conf_name = "{outputs_dir}/{package_name}.conf".format(
        outputs_dir = outputs_dir,
        package_name = package_name,
    )
    package_conf = ctx.actions.declare_file(package_conf_name)
    package_conf_content = """
name: {package_name}
version: {package_version}
id: {package_name}-{package_version}
import-dirs: {outputs_dir}
library-dirs: {outputs_dir}
hs-libraries: HS{package_name}
depends: {all_deps}
""".format(
        package_name = package_name,
        package_version = PACKAGE_VERSION,
        outputs_dir = outputs_dir,
        all_deps = all_deps,
    )
    ctx.actions.write(
        output = package_conf,
        content = package_conf_content,
        is_executable = False,
    )
    package_command_args = ctx.actions.args()
    package_command_args.add("update")
    package_db_arg = "--package-db={}".format(outputs_dir)
    package_command_args.add(package_db_arg)
    package_command_args.add(package_conf_name)
    ctx.actions.run(
        inputs = depset([outputs_dir]),
        outputs = [outputs_dir],
        executable = ctx.executable._ghc_pkg,
        arguments = [package_command_args],
        mnemonic = "GhcPkgLibrary",
        progress_message = "Generating GHC package database: %s" % ctx.label.name,
    )
    return outputs_dir, package_name

def _get_runfile_path(ctx, file):
    if file.short_path.startswith("../"):
        relative_path = file.short_path.split("/", 2)[2]
        return "{}/{}".format(file.owner.workspace_name, relative_path)
    workspace_name = ctx.workspace_name if ctx.workspace_name else "_main"
    return "{}/{}".format(workspace_name, file.short_path)

def _haskell_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name)

    tool_runfiles = []
    tool_dirs = []
    for tool in ctx.files.tools:
        tool_runfiles.append(tool)
        tool_path = _get_runfile_path(ctx, tool)
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
    script_suffix = ""
    library_provider = []
    if ctx.attr._run_type == "haskell_library":
        outputs_dir, package_name = _haskell_library_compile(ctx)
        outputs.append(outputs_dir)
        script_suffix = "echo 'Librería compilada. Las salidas (.hi y .o) están en: $RUNFILES_DIR/{dir}'\n".format(
            dir = _get_runfile_path(ctx, outputs_dir)
        )
        library_provider = [HaskellLibraryInfo(
            pkg_dir = outputs_dir,
            pkg_name = package_name,
            modules = ctx.attr.modules
            dependencies = ctx.attr.deps
        )]
    elif ctx.attr._run_type == "haskell_binary":
        compiled_binary = _haskell_binary_compile(ctx)
        real_binary_runpath = _get_runfile_path(ctx, compiled_binary)
        script_suffix = """
exec "$RUNFILES_DIR/{real_binary}" "$@"
""".format( real_binary = real_binary_runpath )
        outputs.append(compiled_binary)
        runfiles_files.append(compiled_binary)
    elif ctx.attr._run_type == "haskell_repl":
        lib = ctx.attr.lib
        lib_info = lib[HaskellLibraryInfo]
        lib_dir = lib_info.hi_dir
        lib_modules = lib_info.modules
        lib_runpath = _get_runfile_path(ctx, lib_dir)
        ghc_runpath = _get_runfile_path(ctx, ctx.executable._ghc)
        runfiles_files.extend(lib[DefaultInfo].files.to_list())
        load_command = " ".join(lib_modules)
        script_suffix = """
exec "$RUNFILES_DIR/{ghc}" --interactive -i"$RUNFILES_DIR/{lib_dir}" -e ":load {modules}"
""".format(
            ghc = ghc_runpath,
            lib_dir = lib_runpath,
            modules = load_command,
        )
        runfiles_files.append(ctx.executable._ghc)

    ctx.actions.write(
        output = script,
        content = common_script_content + script_suffix,
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        files = depset(outputs),
        runfiles = ctx.runfiles(files = runfiles_files),
    )] + library_provider

def _make_haskell_rule(run_type, ghc_cfg):
    attrs = {
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
        "_ghc_pkg": attr.label(
            default = Label("@nix_ghc//:ghc-pkg"),
            executable = True,
            cfg = ghc_cfg,
        ),
        "_ghc_ar": attr.label(
            default = Label("@nix_ghc//:ghc-ar"),
            executable = True,
            cfg = ghc_cfg,
        ),
    }
    if run_type == "haskell_library":
        attrs["srcs"] = attr.label_list(allow_files = [".hs"])
        attrs["modules"] = attr.string_list(default = [])
        attrs["deps"] = attr.label_list(providers = [HaskellLibraryInfo], default = [])
        attrs["deps_external"] = attr.string_list(default = [])
    elif run_type == "haskell_binary":
        attrs["srcs"] = attr.label_list(allow_files = [".hs"])
        attrs["deps"] = attr.label_list(providers = [HaskellLibraryInfo], default = [])
    elif run_type == "haskell_repl":
        attrs["lib"] = attr.label(providers = [HaskellLibraryInfo], mandatory = True)
    return rule(
        implementation = _haskell_impl,
        executable = (run_type != "haskell_library"),
        attrs = attrs,
    )

haskell_repl = _make_haskell_rule("haskell_repl", "target")
haskell_binary = _make_haskell_rule("haskell_binary", "exec")
haskell_library = _make_haskell_rule("haskell_library", "target")
