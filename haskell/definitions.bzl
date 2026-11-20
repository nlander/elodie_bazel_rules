HaskellLibraryInfo = provider(
    doc = "Información de una librería de Haskell",
    fields = [
        "sources",
        "modules",
        "dependencies",
        "external_dependencies",
    ],
)

HaskellPackagedLibrary = provider(
    doc = "Paquete compilado y enlazado de una librería de Haskell",
    fields = [
        "pkg_dir",
        "pkg_name",
        "modules",
        "dependencies"
    ]
)

PACKAGE_VERSION = "0.1.0"
GHC_VERSION = "9.10.3"
PKG_SUFFIX = "_pkg"

def _ghc_common_args(library, args, all_inputs):
    lib_info = library[HaskellLibraryInfo]
    all_deps = list(lib_info.external_dependencies)
    if lib_info.dependencies:
        for dep in lib_info.dependencies:
            dep_pkg = dep[HaskellPackagedLibrary]
            dep_dir = dep_pkg.pkg_dir
            dep_name = dep_pkg.pkg_name
            args.add("-package-db", dep_dir.path)
            args.add("-package", dep_name)
            all_inputs.append(dep_dir)
            dep_id = "{package_name}-{package_version}".format(
                package_name = dep_name,
                package_version = PACKAGE_VERSION
            )
            all_deps.append(dep_id)
    return all_inputs, all_deps

def _compilation_output_file_from_module(ctx, module_name, outputs_dir_name, ext):
    object_file_path = "{outputs_dir}/{module_location}.{ext}".format(
        outputs_dir = outputs_dir_name,
        module_location = module_name.replace(".", "/"),
        ext = ext,
    )
    object_file = ctx.actions.declare_file(object_file_path)
    return object_file

def _get_runfile_path(ctx, file):
    if file.short_path.startswith("../"):
        relative_path = file.short_path.split("/", 2)[2]
        return "{}/{}".format(file.owner.workspace_name, relative_path)
    workspace_name = ctx.workspace_name if ctx.workspace_name else "_main"
    return "{}/{}".format(workspace_name, file.short_path)

def _get_source_arg_for_dep(ctx, dep):
    lib_info = dep[HaskellLibraryInfo]
    lib_sources = lib_info.sources
    runfile_paths = [_get_runfile_path(ctx, src) for src in lib_sources]
    source_args = ["$RUNFILES_DIR/{}".format(path) for path in runfile_paths]
    args = " ".join(source_args)
    return args

def _get_package_arg_for_dep(ctx, dep):
    lib_info = dep[HaskellPackagedLibrary]
    lib_dir = lib_info.pkg_dir
    lib_name = lib_info.pkg_name
    runfile_path = _get_runfile_path(ctx, lib_dir)
    args = "-package-db $RUNFILES_DIR/{} -package {}".format(
        runfile_path,
        lib_name,
    )
    return args

def _haskell_library_impl(ctx):
    all_dependencies = list(ctx.attr.dependencies)
    if ctx.attr.dependencies:
        for dep in ctx.attr.dependencies:
            transitive_deps = dep[HaskellPackagedLibrary].dependencies
            all_dependencies.extend(transitive_deps)
    library_provider = [HaskellLibraryInfo(
        sources = ctx.files.sources,
        modules = ctx.attr.modules,
        dependencies = all_dependencies,
        external_dependencies = ctx.attr.external_dependencies,
    )]
    final_runfiles = ctx.runfiles()
    final_runfiles = final_runfiles.merge(ctx.runfiles(files=ctx.files.sources))
    for dep in all_dependencies:
        final_runfiles = final_runfiles.merge(dep[DefaultInfo].default_runfiles)
    return [DefaultInfo(
        runfiles = final_runfiles,
    )] + library_provider

def _haskell_package_impl(ctx):
    library = ctx.attr.library
    outputs_dir_name = ctx.label.name + "_out"
    path_parts = [ctx.bin_dir.path, ctx.label.workspace_root, ctx.label.package, outputs_dir_name]
    filtered_path_parts = [p for p in path_parts if p]
    outputs_dir_path = "/".join(filtered_path_parts)
    package_dir = ctx.actions.declare_directory(ctx.label.name + PKG_SUFFIX)
    package_name = ctx.label.name.replace("_", "-")
    shared_object_name = "{outputs_dir}/libHS{pkg_name}-ghc{ghc_version}.so".format(
        outputs_dir = outputs_dir_name,
        pkg_name = package_name,
        ghc_version = GHC_VERSION,
    )
    shared_object_file = ctx.actions.declare_file(shared_object_name)
    compilation_args = ctx.actions.args()
    compilation_args.add("-c")
    compilation_args.add("-dynamic-too")
    compilation_args.add("-package-name", "{}-{}".format(package_name, PACKAGE_VERSION))
    compilation_args.add("-fPIC")
    compilation_args.add("-O2")
    compilation_args.add("-tmpdir", "/tmp")
    all_inputs = list(library[HaskellLibraryInfo].sources)
    all_inputs, all_deps = _ghc_common_args(library, compilation_args, all_inputs)
    object_files = [_compilation_output_file_from_module(ctx, module, outputs_dir_name, "o") for module in library[HaskellLibraryInfo].modules]
    hi_files = [_compilation_output_file_from_module(ctx, module, outputs_dir_name, "hi") for module in library[HaskellLibraryInfo].modules]
    dyn_object_files = [_compilation_output_file_from_module(ctx, module, outputs_dir_name, "dyn_o") for module in library[HaskellLibraryInfo].modules]
    dyn_hi_files = [_compilation_output_file_from_module(ctx, module, outputs_dir_name, "dyn_hi") for module in library[HaskellLibraryInfo].modules]
    src_depset = depset(library[HaskellLibraryInfo].sources)
    compilation_args.add_all(src_depset)
    compilation_outputs = []
    compilation_outputs.extend(hi_files)
    compilation_outputs.extend(object_files)
    compilation_outputs.extend(dyn_hi_files)
    compilation_outputs.extend(dyn_object_files)
    compilation_args.add("-outputdir", outputs_dir_path)
    ctx.actions.run(
        inputs = depset(all_inputs),
        outputs = compilation_outputs,
        executable = ctx.executable._ghc,
        arguments = [compilation_args],
        env = {"TMPDIR": "/tmp"},
        execution_requirements = {"no-sandbox": "1"},
        mnemonic = "GhcCompileLibrary",
        progress_message = "Compiling Haskell library: %s" % ctx.label.name,
    )
    linking_args = ctx.actions.args()
    linking_args.add("-shared")
    linking_args.add("-dynamic")
    linking_args.add("-o", shared_object_file)
    linking_args.add_all(dyn_object_files)
    all_linking_inputs = dyn_object_files
    all_linking_inputs, all_linking_deps = _ghc_common_args(library, linking_args, all_linking_inputs)
    if library[HaskellLibraryInfo].external_dependencies:
        for dep_ext in library[HaskellLibraryInfo].external_dependencies:
            linking_args.add("-package-id", dep_ext)
    ctx.actions.run(
        inputs = depset(all_linking_inputs),
        outputs = [shared_object_file],
        executable = ctx.executable._ghc,
        arguments = [linking_args],
        execution_requirements = {"no-sandbox": "1"},
        mnemonic = "GhcLinkSharedLibrary",
        progress_message = "Linking shared Haskell library: %s" % ctx.label.name,
    )
    archiving_args = ctx.actions.args()
    archiving_args.add("rcs")
    archive_file_name = "{outputs_dir}/libHS{pkg_name}.a".format(
        outputs_dir = outputs_dir_name,
        pkg_name = package_name,
    )
    archive_file = ctx.actions.declare_file(archive_file_name)
    archiving_args.add(archive_file)
    archiving_args.add_all(object_files)
    ctx.actions.run(
        inputs = depset(object_files),
        outputs = [archive_file],
        executable = ctx.executable._ghc_ar,
        arguments = [archiving_args],
        env = {"TMPDIR": "/tmp"},
        execution_requirements = {"no-sandbox": "1"},
        mnemonic = "GhcArLibrary",
        progress_message = "Archiving Haskell library: %s" % ctx.label.name,
    )
    package_conf_name = "{outputs_dir}/{package_name}.conf".format(
        outputs_dir = outputs_dir_name,
        package_name = package_name,
    )
    package_conf = ctx.actions.declare_file(package_conf_name)
    package_conf_content = """
name: {package_name}
version: {package_version}
id: {package_name}-{package_version}
key: {package_name}-{package_version}
import-dirs: ${{pkgroot}}/{outputs_dir}
library-dirs: ${{pkgroot}}/{outputs_dir}
dynamic-library-dirs: ${{pkgroot}}/{outputs_dir}
hs-libraries: HS{package_name}
exposed-modules: {modules}
depends: {all_deps}
""".format(
        package_name = package_name,
        package_version = PACKAGE_VERSION,
        outputs_dir = outputs_dir_name,
        modules = " ".join(library[HaskellLibraryInfo].modules),
        all_deps = " ".join(all_deps),
    )
    ctx.actions.write(
        output = package_conf,
        content = package_conf_content,
        is_executable = False,
    )
    packaging_args = ctx.actions.args()
    packaging_args.add("update")
    package_db_arg = "--package-db={}".format(package_dir.path)
    if library[HaskellLibraryInfo].dependencies:
        for dep in library[HaskellLibraryInfo].dependencies:
            dep_pkg = dep[HaskellPackagedLibrary]
            packaging_args.add("--package-db=" + dep_pkg.pkg_dir.path)
    packaging_args.add(package_db_arg)
    packaging_args.add(package_conf)
    packaging_inputs = [package_conf, archive_file, shared_object_file]
    ctx.actions.run(
        inputs = depset(packaging_inputs),
        outputs = [package_dir],
        executable = ctx.executable._ghc_pkg,
        arguments = [packaging_args],
        env = {"TMPDIR": "/tmp"},
        execution_requirements = {"no-sandbox": "1"},
        mnemonic = "GhcPkgLibrary",
        progress_message = "Generating GHC package database: %s" % ctx.label.name,
    )
    library_artifacts = hi_files + object_files + dyn_hi_files + dyn_object_files + [archive_file, shared_object_file, package_dir]
    library_provider = [HaskellPackagedLibrary(
        pkg_dir = package_dir,
        pkg_name = package_name,
        modules = library[HaskellLibraryInfo].modules,
        dependencies = library[HaskellLibraryInfo].dependencies,
    )]
    final_runfiles = ctx.runfiles()
    final_runfiles = final_runfiles.merge(ctx.runfiles(files=library_artifacts))
    for dep in library[HaskellLibraryInfo].dependencies:
        final_runfiles = final_runfiles.merge(dep[DefaultInfo].default_runfiles)
    return [DefaultInfo(
        files = depset(library_artifacts),
        runfiles = final_runfiles,
    )] + library_provider

def _haskell_repl_impl(ctx):
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
    script_content = """#!/usr/bin/env bash
if [ -z "$RUNFILES_DIR" ]; then
  if [ -d "${{BASH_SOURCE[0]}}.runfiles" ]; then
    RUNFILES_DIR="${{BASH_SOURCE[0]}}.runfiles"
  else
    RUNFILES_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
  fi
fi
{path_exports}
""".format( path_exports = path_exports )
    final_runfiles = ctx.runfiles(files = tool_runfiles)
    final_runfiles = final_runfiles.merge(ctx.runfiles(files = ctx.files.data))
    source_dependencies = ctx.attr.dependencies
    source_dep_names = [dep.label.name for dep in source_dependencies]
    precompiled_dependencies_set = depset()
    for dep in source_dependencies:
        lib_info = dep[HaskellLibraryInfo]
        for transitive_dep in lib_info.dependencies:
            trans_pkg_name = transitive_dep.label.name
            trans_name = trans_pkg_name.removesuffix(PKG_SUFFIX)
            if trans_name not in source_dep_names:
                precompiled_dependencies_set = depset(transitive = [precompiled_dependencies_set, depset([transitive_dep])])
    precompiled_dependencies = precompiled_dependencies_set.to_list()
    package_args = [_get_package_arg_for_dep(ctx, dep) for dep in precompiled_dependencies]
    package_args_string = " ".join(package_args)
    source_args = [_get_source_arg_for_dep(ctx, dep) for dep in source_dependencies]
    source_args_string = " ".join(source_args)
    ghc_runpath = _get_runfile_path(ctx, ctx.executable._ghc)
    ghci_script_arg = ""
    if ctx.file.ghci_script:
        ghci_script_path = _get_runfile_path(ctx, ctx.file.ghci_script)
        ghci_script_arg = '-e ":script $RUNFILES_DIR/{}"'.format(ghci_script_path)
        final_runfiles = final_runfiles.merge(ctx.runfiles(files = [ctx.file.ghci_script]))
    script_suffix = """
exec "$RUNFILES_DIR/{ghc}" --interactive {precompiled_dependencies} {source_dependencies} {ghci_script_arg}
""".format(
        ghc = ghc_runpath,
        precompiled_dependencies = package_args_string,
        source_dependencies = source_args_string,
        ghci_script_arg = ghci_script_arg,
    )
    for dep in source_dependencies:
        final_runfiles = final_runfiles.merge(dep[DefaultInfo].default_runfiles)
    for dep in precompiled_dependencies:
        final_runfiles = final_runfiles.merge(dep[DefaultInfo].default_runfiles)
    final_runfiles = final_runfiles.merge(
        ctx.runfiles(files = [ctx.executable._ghc])
    )
    ctx.actions.write(
        output = script,
        content = script_content + script_suffix,
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        files = depset([script]),
        runfiles = final_runfiles,
    )]

def _make_haskell_repl_rule():
    attrs = {
        "tools": attr.label_list(
            allow_files = True,
            cfg = "target",
            default = [],
        ),
        "_ghc": attr.label(
            default = Label("@nix_ghc//:ghc"),
            executable = True,
            cfg = "target",
        ),
        "dependencies": attr.label_list(
            providers = [HaskellLibraryInfo],
            default = [],
        ),
        "data": attr.label_list(
            allow_files = True,
            default = [],
        ),
        "ghci_script": attr.label(
            allow_single_file = True,
        ),
    }
    return rule(
        implementation = _haskell_repl_impl,
        executable = True,
        attrs = attrs,
    )

def _make_haskell_package_rule():
    attrs = {
        "_ghc": attr.label(
            default = Label("@nix_ghc//:ghc"),
            executable = True,
            cfg = "target",
        ),
        "_ghc_pkg": attr.label(
            default = Label("@nix_ghc//:ghc-pkg"),
            executable = True,
            cfg = "target",
        ),
        "_ghc_ar": attr.label(
            default = Label("@nix_binutils//:ar"),
            executable = True,
            cfg = "target",
        ),
        "library": attr.label(
            providers = [HaskellLibraryInfo],
            mandatory = True,
        ),
    }
    return rule(
        implementation = _haskell_package_impl,
        executable = False,
        attrs = attrs,
    )

def _make_haskell_library_rule():
    attrs = {
        "sources": attr.label_list(allow_files = [".hs"]),
        "modules": attr.string_list(default = []),
        "dependencies": attr.label_list(
            providers = [HaskellPackagedLibrary],
            default = [],
        ),
        "external_dependencies": attr.string_list(default = []),
    }
    return rule(
        implementation = _haskell_library_impl,
        executable = False,
        attrs = attrs,
    )

def haskell_library(name, sources, modules, dependencies = [], external_dependencies = [], **kwargs):
    dependency_names = []
    for dep in dependencies:
        dep_str = str(dep)
        if ":" in dep_str:
            pkg_part, target_part = dep_str.rsplit(":", 1)
            dependency_names.append("{}:{}{}".format(pkg_part, target_part, PKG_SUFFIX))
        else:
            dependency_names.append("{}{}".format(dep_str, PKG_SUFFIX))
    haskell_library_info(
        name = name,
        sources = sources,
        modules = modules,
        dependencies = dependency_names,
        external_dependencies = external_dependencies,
        **kwargs
    )
    haskell_package(
        name = name + PKG_SUFFIX,
        library = ":" + name,
        **kwargs
    )

haskell_repl = _make_haskell_repl_rule()
haskell_library_info = _make_haskell_library_rule()
haskell_package = _make_haskell_package_rule()
