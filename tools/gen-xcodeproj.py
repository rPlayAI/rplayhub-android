#!/usr/bin/env python3
"""
Regenerate app/rPlayHubAndroid.xcodeproj from whatever .swift files are in the source directory.

The project has no per-file settings, so it is entirely derived from the file lists: every
.swift in rPlayHubAndroid/ goes into the app, every .swift in FinderMount/ (plus the SHARED adb
client files) into the File Provider extension, which the app embeds. Generating it means adding
a source file never involves editing a pbxproj by hand, and never silently fails to compile
because it was forgotten.

    python3 tools/gen-xcodeproj.py
"""
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
SRC = 'rPlayHubAndroid'
EXT = 'FinderMount'

# Files the File Provider extension compiles too. It is a separate process with its own module,
# so sharing means compiling the same sources into both targets — these three are pure
# Foundation/Darwin (the adb client), which is exactly what the extension needs and all it needs.
SHARED = ['Adb.swift', 'AdbFiles.swift', 'TCPSocket.swift']

files = sorted(f for f in os.listdir(os.path.join(ROOT, SRC)) if f.endswith('.swift'))
ext_files = sorted(f for f in os.listdir(os.path.join(ROOT, EXT)) if f.endswith('.swift'))

def oid(n):
    return "1A%022X" % n

refs, builds, entries = [], [], []
n = 0x1000
for f in files:
    n += 1; fr = oid(n)
    n += 1; bf = oid(n)
    refs.append(f'\t\t{fr} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
    builds.append(f'\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f} */; }};')
    entries.append((f, fr, bf))

# The extension's own sources, plus a second build file for each shared source (one PBXBuildFile
# per target — the file reference itself is reused).
ext_refs, ext_builds, ext_entries, ext_group = [], [], [], []
n = 0x8000
for f in ext_files:
    n += 1; fr = oid(n)
    n += 1; bf = oid(n)
    ext_refs.append(f'\t\t{fr} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
    ext_builds.append(f'\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f} */; }};')
    ext_entries.append((f, bf))
    ext_group.append((f, fr))
shared_missing = [f for f in SHARED if f not in files]
if shared_missing:
    raise SystemExit(f"shared sources not found in {SRC}: {shared_missing}")
for f in SHARED:
    fr = next(r for name, r, _ in entries if name == f)
    n += 1; bf = oid(n)
    ext_builds.append(f'\t\t{bf} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {f} */; }};')
    ext_entries.append((f, bf))

PLIST_REF, ENT_REF, ICON_REF = oid(0x2001), oid(0x2002), oid(0x2003)
ICON_BUILD = oid(0x2004)
PRODUCT, TARGET, PROJECT = oid(0x3001), oid(0x3002), oid(0x3003)
GRP_ROOT, GRP_SRC, GRP_PRODUCTS = oid(0x4001), oid(0x4002), oid(0x4003)
PH_SOURCES, PH_FRAMEWORKS, PH_RESOURCES = oid(0x5001), oid(0x5002), oid(0x5003)
PH_BUNDLE_AGENT = oid(0x5004)
CFG_LIST_PROJ, CFG_LIST_TGT = oid(0x6001), oid(0x6002)
CFG_PD, CFG_PR, CFG_TD, CFG_TR = oid(0x6003), oid(0x6004), oid(0x6005), oid(0x6006)

# The File Provider extension target and everything that hangs off it: its own product, group,
# phases and configurations, plus the app-side Embed phase, dependency and proxy that put the
# built .appex into the app's PlugIns and sign it there.
EXT_PLIST_REF, EXT_ENT_REF = oid(0x7001), oid(0x7002)
EXT_PRODUCT, EXT_TARGET = oid(0x7003), oid(0x7004)
GRP_EXT = oid(0x7005)
PH_EXT_SOURCES, PH_EXT_FRAMEWORKS, PH_EMBED = oid(0x7006), oid(0x7007), oid(0x7008)
CFG_LIST_EXT, CFG_XD, CFG_XR = oid(0x7009), oid(0x700A), oid(0x700B)
EXT_DEP, EXT_PROXY, EXT_EMBED_BUILD = oid(0x700C), oid(0x700D), oid(0x700E)

group_children = "\n".join(f'\t\t\t\t{fr} /* {f} */,' for f, fr, _ in entries)
sources_files  = "\n".join(f'\t\t\t\t{bf} /* {f} in Sources */,' for f, _, bf in entries)
ext_group_children = "\n".join(f'\t\t\t\t{fr} /* {f} */,' for f, fr in ext_group)
ext_sources_files  = "\n".join(f'\t\t\t\t{bf} /* {f} in Sources */,' for f, bf in ext_entries)

common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.0;"""

target_common = """				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				INFOPLIST_FILE = rPlayHubAndroid/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = ai.rplay.rplayhub.android;
				PRODUCT_NAME = "$(TARGET_NAME)";"""

ext_target_common = """				APPLICATION_EXTENSION_API_ONLY = YES;
				CODE_SIGN_ENTITLEMENTS = FinderMount/FinderMount.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				INFOPLIST_FILE = FinderMount/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
					"@executable_path/../../../../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = ai.rplay.rplayhub.android.FinderMount;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;"""

SHELL_SCRIPT_RAW = r'''set -e
if [ "${CONFIGURATION}" != "Release" ]; then exit 0; fi
APP="${CODESIGNING_FOLDER_PATH}"
ROOT="${SRCROOT}/.."
AGENT_DIR="${RPLAYHUB_AGENT_DIR:-$ROOT/build/agent}"
if [ -f "$AGENT_DIR/screen-sharing-agent.jar" ]; then
  rm -rf "$APP/Contents/Resources/agent"
  cp -R "$AGENT_DIR" "$APP/Contents/Resources/agent"
else
  echo "warning: no built agent at $AGENT_DIR - mirroring will not work"
fi
ADB=""
for c in /opt/homebrew/share/android-commandlinetools/platform-tools/adb /opt/homebrew/bin/adb /usr/local/bin/adb; do
  if [ -x "$c" ]; then ADB="$c"; break; fi
done
if [ -n "$ADB" ]; then
  cp "$ADB" "$APP/Contents/MacOS/adb"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --entitlements "$ROOT/app/rPlayHubAndroid/adb-inherit.entitlements" "$APP/Contents/MacOS/adb"
else
  echo "warning: no adb binary found to bundle"
fi
BRIDGE=""
for c in "$ROOT/emulator-transport/.build/arm64-apple-macosx/release/emulator-bridge" "$ROOT/emulator-transport/.build/arm64-apple-macosx/debug/emulator-bridge"; do
  if [ -x "$c" ]; then BRIDGE="$c"; break; fi
done
if [ -n "$BRIDGE" ]; then
  cp "$BRIDGE" "$APP/Contents/MacOS/emulator-bridge"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --entitlements "$ROOT/app/rPlayHubAndroid/adb-inherit.entitlements" "$APP/Contents/MacOS/emulator-bridge"
else
  echo "warning: no emulator-bridge (cd emulator-transport && swift build -c release --product emulator-bridge) - emulator hosting will fall back to adb"
fi
COMPANION="$ROOT/helper/app/build/outputs/apk/debug/app-debug.apk"
if [ -f "$COMPANION" ]; then
  cp "$COMPANION" "$APP/Contents/Resources/companion.apk"
else
  echo "warning: no companion apk (run tools/build-helper.sh) - Install Companion App will be unavailable"
fi
LEGACY="$ROOT/build/legacy-agent/rplayhub-legacy.dex"
if [ -f "$LEGACY" ]; then
  cp "$LEGACY" "$APP/Contents/Resources/rplayhub-legacy.dex"
else
  echo "warning: no legacy agent (run tools/build-legacy-agent.sh) - Android 5.0-7.1 devices will not mirror"
fi'''
SHELL_SCRIPT = (SHELL_SCRIPT_RAW.replace(chr(92), chr(92)*2)
                .replace(chr(34), chr(92)+chr(34)).replace(chr(10), chr(92)+'n'))

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(builds)}
{chr(10).join(ext_builds)}
		{ICON_BUILD} /* AppIcon.icns in Resources */ = {{isa = PBXBuildFile; fileRef = {ICON_REF} /* AppIcon.icns */; }};
		{EXT_EMBED_BUILD} /* FinderMount.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {EXT_PRODUCT} /* FinderMount.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{EXT_PROXY} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {PROJECT} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {EXT_TARGET};
			remoteInfo = FinderMount;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		{PH_EMBED} /* Embed Foundation Extensions */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				{EXT_EMBED_BUILD} /* FinderMount.appex in Embed Foundation Extensions */,
			);
			name = "Embed Foundation Extensions";
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
{chr(10).join(refs)}
		{PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{ICON_REF} /* AppIcon.icns */ = {{isa = PBXFileReference; lastKnownFileType = image.icns; path = AppIcon.icns; sourceTree = "<group>"; }};
		{ENT_REF} /* rPlayHubAndroid.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = rPlayHubAndroid.entitlements; sourceTree = "<group>"; }};
		{PRODUCT} /* rPlayHubAndroid.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = rPlayHubAndroid.app; sourceTree = BUILT_PRODUCTS_DIR; }};
{chr(10).join(ext_refs)}
		{EXT_PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{EXT_ENT_REF} /* FinderMount.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = FinderMount.entitlements; sourceTree = "<group>"; }};
		{EXT_PRODUCT} /* FinderMount.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = FinderMount.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{PH_FRAMEWORKS} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{PH_EXT_FRAMEWORKS} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{GRP_ROOT} = {{
			isa = PBXGroup;
			children = (
				{GRP_SRC} /* rPlayHubAndroid */,
				{GRP_EXT} /* FinderMount */,
				{GRP_PRODUCTS} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{GRP_SRC} /* rPlayHubAndroid */ = {{
			isa = PBXGroup;
			children = (
{group_children}
				{ICON_REF} /* AppIcon.icns */,
				{PLIST_REF} /* Info.plist */,
				{ENT_REF} /* rPlayHubAndroid.entitlements */,
			);
			path = rPlayHubAndroid;
			sourceTree = "<group>";
		}};
		{GRP_EXT} /* FinderMount */ = {{
			isa = PBXGroup;
			children = (
{ext_group_children}
				{EXT_PLIST_REF} /* Info.plist */,
				{EXT_ENT_REF} /* FinderMount.entitlements */,
			);
			path = FinderMount;
			sourceTree = "<group>";
		}};
		{GRP_PRODUCTS} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PRODUCT} /* rPlayHubAndroid.app */,
				{EXT_PRODUCT} /* FinderMount.appex */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{TARGET} /* rPlayHubAndroid */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "rPlayHubAndroid" */;
			buildPhases = (
				{PH_SOURCES} /* Sources */,
				{PH_FRAMEWORKS} /* Frameworks */,
				{PH_RESOURCES} /* Resources */,
				{PH_EMBED} /* Embed Foundation Extensions */,
				{PH_BUNDLE_AGENT} /* Bundle agent + adb */,
			);
			buildRules = (
			);
			dependencies = (
				{EXT_DEP} /* PBXTargetDependency */,
			);
			name = rPlayHubAndroid;
			productName = rPlayHubAndroid;
			productReference = {PRODUCT} /* rPlayHubAndroid.app */;
			productType = "com.apple.product-type.application";
		}};
		{EXT_TARGET} /* FinderMount */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CFG_LIST_EXT} /* Build configuration list for PBXNativeTarget "FinderMount" */;
			buildPhases = (
				{PH_EXT_SOURCES} /* Sources */,
				{PH_EXT_FRAMEWORKS} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = FinderMount;
			productName = FinderMount;
			productReference = {EXT_PRODUCT} /* FinderMount.appex */;
			productType = "com.apple.product-type.app-extension";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{TARGET} = {{
						CreatedOnToolsVersion = 15.0;
					}};
					{EXT_TARGET} = {{
						CreatedOnToolsVersion = 15.0;
					}};
				}};
			}};
			buildConfigurationList = {CFG_LIST_PROJ} /* Build configuration list for PBXProject "rPlayHubAndroid" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {GRP_ROOT};
			productRefGroup = {GRP_PRODUCTS} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{TARGET} /* rPlayHubAndroid */,
				{EXT_TARGET} /* FinderMount */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{PH_RESOURCES} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{ICON_BUILD} /* AppIcon.icns in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		{PH_BUNDLE_AGENT} /* Bundle agent + adb */ = {{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
			);
			name = "Bundle agent + adb";
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "{SHELL_SCRIPT}";
		}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{PH_SOURCES} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{PH_EXT_SOURCES} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{ext_sources_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{EXT_DEP} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {EXT_TARGET} /* FinderMount */;
			targetProxy = {EXT_PROXY} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		{CFG_PD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{CFG_PR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common}
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				MTL_ENABLE_DEBUG_INFO = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		{CFG_TD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_ENTITLEMENTS = rPlayHubAndroid/rPlayHubAndroid-dev.entitlements;
{target_common}
			}};
			name = Debug;
		}};
		{CFG_TR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_ENTITLEMENTS = rPlayHubAndroid/rPlayHubAndroid.entitlements;
{target_common}
			}};
			name = Release;
		}};
		{CFG_XD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{ext_target_common}
			}};
			name = Debug;
		}};
		{CFG_XR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{ext_target_common}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{CFG_LIST_PROJ} /* Build configuration list for PBXProject "rPlayHubAndroid" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG_PD} /* Debug */,
				{CFG_PR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{CFG_LIST_TGT} /* Build configuration list for PBXNativeTarget "rPlayHubAndroid" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG_TD} /* Debug */,
				{CFG_TR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{CFG_LIST_EXT} /* Build configuration list for PBXNativeTarget "FinderMount" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{CFG_XD} /* Debug */,
				{CFG_XR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {PROJECT} /* Project object */;
}}
"""

out = os.path.join(ROOT, 'rPlayHubAndroid.xcodeproj', 'project.pbxproj')
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, 'w').write(pbx)
print(f"wrote {os.path.relpath(out)} — {len(files)} app sources, "
      f"{len(ext_files)} + {len(SHARED)} shared extension sources")
