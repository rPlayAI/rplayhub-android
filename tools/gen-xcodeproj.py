#!/usr/bin/env python3
"""
Regenerate app/rPlayHubAndroid.xcodeproj from whatever .swift files are in the source directory.

The project has no per-file settings and no build phases beyond the default three, so it is
entirely derived from the file list. Generating it means adding a source file never involves
editing a pbxproj by hand, and never silently fails to compile because it was forgotten.

    python3 tools/gen-xcodeproj.py
"""
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')
SRC = 'rPlayHubAndroid'

files = sorted(f for f in os.listdir(os.path.join(ROOT, SRC)) if f.endswith('.swift'))

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

PLIST_REF, ENT_REF, ICON_REF = oid(0x2001), oid(0x2002), oid(0x2003)
ICON_BUILD = oid(0x2004)
PRODUCT, TARGET, PROJECT = oid(0x3001), oid(0x3002), oid(0x3003)
GRP_ROOT, GRP_SRC, GRP_PRODUCTS = oid(0x4001), oid(0x4002), oid(0x4003)
PH_SOURCES, PH_FRAMEWORKS, PH_RESOURCES = oid(0x5001), oid(0x5002), oid(0x5003)
CFG_LIST_PROJ, CFG_LIST_TGT = oid(0x6001), oid(0x6002)
CFG_PD, CFG_PR, CFG_TD, CFG_TR = oid(0x6003), oid(0x6004), oid(0x6005), oid(0x6006)

group_children = "\n".join(f'\t\t\t\t{fr} /* {f} */,' for f, fr, _ in entries)
sources_files  = "\n".join(f'\t\t\t\t{bf} /* {f} in Sources */,' for f, _, bf in entries)

common = """				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
				SWIFT_VERSION = 5.0;"""

target_common = """				CODE_SIGN_ENTITLEMENTS = rPlayHubAndroid/rPlayHubAndroid.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				INFOPLIST_FILE = rPlayHubAndroid/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.rplay.rplayhub.android;
				PRODUCT_NAME = "$(TARGET_NAME)";"""

pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(builds)}
		{ICON_BUILD} /* AppIcon.icns in Resources */ = {{isa = PBXBuildFile; fileRef = {ICON_REF} /* AppIcon.icns */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(refs)}
		{PLIST_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{ICON_REF} /* AppIcon.icns */ = {{isa = PBXFileReference; lastKnownFileType = image.icns; path = AppIcon.icns; sourceTree = "<group>"; }};
		{ENT_REF} /* rPlayHubAndroid.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = rPlayHubAndroid.entitlements; sourceTree = "<group>"; }};
		{PRODUCT} /* rPlayHubAndroid.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = rPlayHubAndroid.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{PH_FRAMEWORKS} /* Frameworks */ = {{
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
		{GRP_PRODUCTS} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{PRODUCT} /* rPlayHubAndroid.app */,
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
			);
			buildRules = (
			);
			dependencies = (
			);
			name = rPlayHubAndroid;
			productName = rPlayHubAndroid;
			productReference = {PRODUCT} /* rPlayHubAndroid.app */;
			productType = "com.apple.product-type.application";
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

/* Begin PBXSourcesBuildPhase section */
		{PH_SOURCES} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

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
{target_common}
			}};
			name = Debug;
		}};
		{CFG_TR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{target_common}
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
/* End XCConfigurationList section */
	}};
	rootObject = {PROJECT} /* Project object */;
}}
"""

out = os.path.join(ROOT, 'rPlayHubAndroid.xcodeproj', 'project.pbxproj')
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, 'w').write(pbx)
print(f"wrote {os.path.relpath(out)} — {len(files)} sources")
