#!/usr/bin/env python3
"""Generate HybridAthlete.xcodeproj from the files on disk.

Run this after adding or removing a source file:

    python3 Scripts/generate_xcodeproj.py

The output is a plain Xcode 14+ project file (objectVersion 56) with an app
target and a unit-test target. Identifiers are derived from file paths, so
regenerating produces a stable diff instead of churning every UUID.

XcodeGen is supported as an alternative and reads the same layout from
project.yml; either tool produces an equivalent project.
"""

from __future__ import annotations

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP_NAME = "HybridAthlete"
TEST_NAME = "HybridAthleteTests"
BUNDLE_ID = "app.hybridathlete.ios"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

APP_SOURCE_DIR = "HybridAthlete"
TEST_SOURCE_DIR = "Tests"

RESOURCE_EXTENSIONS = {".xcassets"}
SKIP_NAMES = {".DS_Store"}


def uid(*parts: str) -> str:
    """Deterministic 24-character hex identifier."""
    digest = hashlib.sha1("::".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def collect(directory: str):
    """Returns (swift_files, resource_dirs, other_files) relative to ROOT."""
    swift, resources, other = [], [], []
    base = os.path.join(ROOT, directory)
    for dirpath, dirnames, filenames in os.walk(base):
        # Asset catalogues are single resource references, not folders to walk.
        for name in list(dirnames):
            if os.path.splitext(name)[1] in RESOURCE_EXTENSIONS:
                resources.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
                dirnames.remove(name)
        dirnames.sort()
        for name in sorted(filenames):
            if name in SKIP_NAMES:
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
            ext = os.path.splitext(name)[1]
            if ext == ".swift":
                swift.append(rel)
            elif ext in {".plist", ".entitlements"}:
                other.append(rel)
    return sorted(swift), sorted(resources), sorted(other)


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".xcassets": "folder.assetcatalog",
    ".json": "text.json",
}


class Project:
    def __init__(self):
        self.objects: list[str] = []
        self.sections: dict[str, list[str]] = {}

    def add(self, section: str, line: str):
        self.sections.setdefault(section, []).append(line)

    def render(self) -> str:
        order = [
            "PBXBuildFile", "PBXContainerItemProxy", "PBXFileReference",
            "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget",
            "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
            "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList",
        ]
        out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {",
               "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]
        for section in order:
            lines = self.sections.get(section)
            if not lines:
                continue
            out.append(f"/* Begin {section} section */")
            out.extend(sorted(lines))
            out.append(f"/* End {section} section */")
            out.append("")
        out.append("\t};")
        out.append(f"\trootObject = {uid('project')} /* Project object */;")
        out.append("}")
        out.append("")
        return "\n".join(out)


def build() -> str:
    app_swift, app_resources, app_other = collect(APP_SOURCE_DIR)
    test_swift, _, _ = collect(TEST_SOURCE_DIR)

    if not app_swift:
        sys.exit(f"No Swift files found under {APP_SOURCE_DIR}/")

    p = Project()

    app_product = uid("product", APP_NAME)
    test_product = uid("product", TEST_NAME)
    app_target = uid("target", APP_NAME)
    test_target = uid("target", TEST_NAME)
    project_id = uid("project")
    main_group = uid("group", "root")
    products_group = uid("group", "Products")

    # --- File references -----------------------------------------------------
    file_refs: dict[str, str] = {}

    def file_ref(rel_path: str) -> str:
        if rel_path in file_refs:
            return file_refs[rel_path]
        ref = uid("fileref", rel_path)
        name = os.path.basename(rel_path)
        ext = os.path.splitext(name)[1]
        ftype = FILE_TYPES.get(ext, "text")
        p.add("PBXFileReference",
              f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; '
              f'lastKnownFileType = {ftype}; path = {name}; sourceTree = "<group>"; }};')
        file_refs[rel_path] = ref
        return ref

    p.add("PBXFileReference",
          f'\t\t{app_product} /* {APP_NAME}.app */ = {{isa = PBXFileReference; '
          f'explicitFileType = wrapper.application; includeInIndex = 0; '
          f'path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    p.add("PBXFileReference",
          f'\t\t{test_product} /* {TEST_NAME}.xctest */ = {{isa = PBXFileReference; '
          f'explicitFileType = wrapper.cfbundle; includeInIndex = 0; '
          f'path = {TEST_NAME}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')

    # --- Groups mirroring the folder tree -----------------------------------
    all_paths = app_swift + app_resources + app_other + test_swift
    children: dict[str, set] = {}
    for rel in all_paths:
        parts = rel.split(os.sep)
        for depth in range(len(parts)):
            parent = os.sep.join(parts[:depth]) if depth else ""
            child = os.sep.join(parts[:depth + 1])
            children.setdefault(parent, set()).add(child)

    def group_id(path: str) -> str:
        return main_group if path == "" else uid("group", path)

    def emit_group(path: str):
        entries = []
        for child in sorted(children.get(path, [])):
            if child in children:            # directory
                entries.append(f"\t\t\t\t{group_id(child)} /* {os.path.basename(child)} */,")
                emit_group(child)
            else:                            # leaf file
                entries.append(f"\t\t\t\t{file_ref(child)} /* {os.path.basename(child)} */,")
        if path == "":
            entries.append(f"\t\t\t\t{products_group} /* Products */,")

        name = os.path.basename(path) if path else "MainGroup"
        body = "\n".join(entries)
        path_attr = f'path = {os.path.basename(path)}; ' if path else ""
        p.add("PBXGroup",
              f'\t\t{group_id(path)} /* {name} */ = {{\n'
              f'\t\t\tisa = PBXGroup;\n'
              f'\t\t\tchildren = (\n{body}\n\t\t\t);\n'
              f'\t\t\t{path_attr}sourceTree = "<group>";\n'
              f'\t\t}};')

    emit_group("")

    p.add("PBXGroup",
          f'\t\t{products_group} /* Products */ = {{\n'
          f'\t\t\tisa = PBXGroup;\n'
          f'\t\t\tchildren = (\n'
          f'\t\t\t\t{app_product} /* {APP_NAME}.app */,\n'
          f'\t\t\t\t{test_product} /* {TEST_NAME}.xctest */,\n'
          f'\t\t\t);\n'
          f'\t\t\tname = Products;\n'
          f'\t\t\tsourceTree = "<group>";\n'
          f'\t\t}};')

    # --- Build files & phases -----------------------------------------------
    def build_files(paths, target_name, phase_label):
        ids = []
        for rel in paths:
            bid = uid("buildfile", target_name, rel)
            ref = file_ref(rel)
            name = os.path.basename(rel)
            p.add("PBXBuildFile",
                  f'\t\t{bid} /* {name} in {phase_label} */ = {{isa = PBXBuildFile; '
                  f'fileRef = {ref} /* {name} */; }};')
            ids.append(f"\t\t\t\t{bid} /* {name} in {phase_label} */,")
        return "\n".join(ids)

    app_sources_phase = uid("phase", "sources", APP_NAME)
    app_resources_phase = uid("phase", "resources", APP_NAME)
    app_frameworks_phase = uid("phase", "frameworks", APP_NAME)
    test_sources_phase = uid("phase", "sources", TEST_NAME)
    test_frameworks_phase = uid("phase", "frameworks", TEST_NAME)

    p.add("PBXSourcesBuildPhase",
          f'\t\t{app_sources_phase} = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n'
          f'\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'
          f'{build_files(app_swift, APP_NAME, "Sources")}\n\t\t\t);\n'
          f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    p.add("PBXResourcesBuildPhase",
          f'\t\t{app_resources_phase} = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n'
          f'\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'
          f'{build_files(app_resources, APP_NAME, "Resources")}\n\t\t\t);\n'
          f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    p.add("PBXSourcesBuildPhase",
          f'\t\t{test_sources_phase} = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n'
          f'\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'
          f'{build_files(test_swift, TEST_NAME, "Sources")}\n\t\t\t);\n'
          f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

    for phase in (app_frameworks_phase, test_frameworks_phase):
        p.add("PBXFrameworksBuildPhase",
              f'\t\t{phase} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; '
              f'files = (\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; }};')

    # --- Test target depends on the app -------------------------------------
    proxy = uid("proxy", TEST_NAME)
    dependency = uid("dependency", TEST_NAME)
    p.add("PBXContainerItemProxy",
          f'\t\t{proxy} = {{\n\t\t\tisa = PBXContainerItemProxy;\n'
          f'\t\t\tcontainerPortal = {project_id} /* Project object */;\n'
          f'\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {app_target};\n'
          f'\t\t\tremoteInfo = {APP_NAME};\n\t\t}};')
    p.add("PBXTargetDependency",
          f'\t\t{dependency} = {{\n\t\t\tisa = PBXTargetDependency;\n'
          f'\t\t\ttarget = {app_target} /* {APP_NAME} */;\n'
          f'\t\t\ttargetProxy = {proxy};\n\t\t}};')

    # --- Build settings ------------------------------------------------------
    base_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
    }
    debug_extra = {
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        'GCC_PREPROCESSOR_DEFINITIONS': '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
    }
    release_extra = {
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "VALIDATE_PRODUCT": "YES",
    }
    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": f"{APP_SOURCE_DIR}/Resources/{APP_NAME}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_SOURCE_DIR}/Resources/Info.plist",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": '"1"',
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
    }
    test_settings = {
        "BUNDLE_LOADER": '"$(TEST_HOST)"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.tests",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "TARGETED_DEVICE_FAMILY": '"1"',
        "TEST_HOST": f'"$(BUILT_PRODUCTS_DIR)/{APP_NAME}.app/$(BUILT_PRODUCTS_DIR:dir)/{APP_NAME}"',
    }
    # TEST_HOST must point at the binary inside the app bundle.
    test_settings["TEST_HOST"] = f'"$(BUILT_PRODUCTS_DIR)/{APP_NAME}.app/{APP_NAME}"'

    def settings_block(settings: dict) -> str:
        return "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(settings.items()))

    def add_config(owner: str, config: str, settings: dict) -> str:
        cid = uid("buildconfig", owner, config)
        p.add("XCBuildConfiguration",
              f'\t\t{cid} /* {config} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n'
              f'\t\t\tbuildSettings = {{\n{settings_block(settings)}\n\t\t\t}};\n'
              f'\t\t\tname = {config};\n\t\t}};')
        return cid

    def add_config_list(owner: str, debug_id: str, release_id: str) -> str:
        lid = uid("configlist", owner)
        p.add("XCConfigurationList",
              f'\t\t{lid} = {{\n\t\t\tisa = XCConfigurationList;\n'
              f'\t\t\tbuildConfigurations = (\n'
              f'\t\t\t\t{debug_id} /* Debug */,\n\t\t\t\t{release_id} /* Release */,\n'
              f'\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n'
              f'\t\t\tdefaultConfigurationName = Release;\n\t\t}};')
        return lid

    project_config_list = add_config_list(
        "project",
        add_config("project", "Debug", {**base_settings, **debug_extra}),
        add_config("project", "Release", {**base_settings, **release_extra}),
    )
    app_config_list = add_config_list(
        APP_NAME,
        add_config(APP_NAME, "Debug", app_settings),
        add_config(APP_NAME, "Release", app_settings),
    )
    test_config_list = add_config_list(
        TEST_NAME,
        add_config(TEST_NAME, "Debug", test_settings),
        add_config(TEST_NAME, "Release", test_settings),
    )

    # --- Targets -------------------------------------------------------------
    p.add("PBXNativeTarget",
          f'\t\t{app_target} /* {APP_NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n'
          f'\t\t\tbuildConfigurationList = {app_config_list};\n'
          f'\t\t\tbuildPhases = (\n\t\t\t\t{app_sources_phase},\n'
          f'\t\t\t\t{app_frameworks_phase},\n\t\t\t\t{app_resources_phase},\n\t\t\t);\n'
          f'\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n'
          f'\t\t\tname = {APP_NAME};\n\t\t\tproductName = {APP_NAME};\n'
          f'\t\t\tproductReference = {app_product} /* {APP_NAME}.app */;\n'
          f'\t\t\tproductType = "com.apple.product-type.application";\n\t\t}};')

    p.add("PBXNativeTarget",
          f'\t\t{test_target} /* {TEST_NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n'
          f'\t\t\tbuildConfigurationList = {test_config_list};\n'
          f'\t\t\tbuildPhases = (\n\t\t\t\t{test_sources_phase},\n'
          f'\t\t\t\t{test_frameworks_phase},\n\t\t\t);\n'
          f'\t\t\tbuildRules = (\n\t\t\t);\n'
          f'\t\t\tdependencies = (\n\t\t\t\t{dependency},\n\t\t\t);\n'
          f'\t\t\tname = {TEST_NAME};\n\t\t\tproductName = {TEST_NAME};\n'
          f'\t\t\tproductReference = {test_product} /* {TEST_NAME}.xctest */;\n'
          f'\t\t\tproductType = "com.apple.product-type.bundle.unit-test";\n\t\t}};')

    p.add("PBXProject",
          f'\t\t{project_id} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n'
          f'\t\t\tattributes = {{\n'
          f'\t\t\t\tBuildIndependentTargetsInParallel = 1;\n'
          f'\t\t\t\tLastSwiftUpdateCheck = 1600;\n'
          f'\t\t\t\tLastUpgradeCheck = 1600;\n'
          f'\t\t\t\tTargetAttributes = {{\n'
          f'\t\t\t\t\t{app_target} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n\t\t\t\t\t}};\n'
          f'\t\t\t\t\t{test_target} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n'
          f'\t\t\t\t\t\tTestTargetID = {app_target};\n\t\t\t\t\t}};\n'
          f'\t\t\t\t}};\n\t\t\t}};\n'
          f'\t\t\tbuildConfigurationList = {project_config_list};\n'
          f'\t\t\tcompatibilityVersion = "Xcode 14.0";\n'
          f'\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n'
          f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n'
          f'\t\t\tmainGroup = {main_group};\n'
          f'\t\t\tproductRefGroup = {products_group} /* Products */;\n'
          f'\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
          f'\t\t\ttargets = (\n\t\t\t\t{app_target} /* {APP_NAME} */,\n'
          f'\t\t\t\t{test_target} /* {TEST_NAME} */,\n\t\t\t);\n\t\t}};')

    return p.render()


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{app}.app"
               BlueprintName = "{app}"
               ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{test}.xctest"
               BlueprintName = "{test}"
               ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


def main():
    project_dir = os.path.join(ROOT, f"{APP_NAME}.xcodeproj")
    scheme_dir = os.path.join(project_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)

    with open(os.path.join(project_dir, "project.pbxproj"), "w") as handle:
        handle.write(build())

    with open(os.path.join(scheme_dir, f"{APP_NAME}.xcscheme"), "w") as handle:
        handle.write(SCHEME.format(app=APP_NAME, test=TEST_NAME,
                                   app_target=uid("target", APP_NAME),
                                   test_target=uid("target", TEST_NAME)))

    print(f"Wrote {os.path.relpath(project_dir, ROOT)}")


if __name__ == "__main__":
    main()
