import os
import re

os.makedirs('Totorox.xcodeproj', exist_ok=True)
with open(os.path.join('3105_repo', 'ThreeOneOSFive.xcodeproj', 'project.pbxproj'), 'r', encoding='utf-8') as f:
    orig = f.read()

# Replace product & directory names
text = orig.replace('ThreeOneOSFive-Bridging-Header.h', 'Tororox-Bridging-Header.h')
text = text.replace('ThreeOneOSFive', 'Totorox')
text = text.replace('3105.app', 'Totorox.app')
text = text.replace('MARKETING_VERSION = 2.0;', 'MARKETING_VERSION = 1.0;')
text = text.replace('CURRENT_PROJECT_VERSION = 8;', 'CURRENT_PROJECT_VERSION = 1;')
text = text.replace('INFOPLIST_KEY_CFBundleDisplayName = 3105;', 'INFOPLIST_KEY_CFBundleDisplayName = Totorox;')
text = text.replace('PRODUCT_NAME = 3105;', 'PRODUCT_NAME = Totorox;')

# Add build files in PBXBuildFile section
build_files_to_add = """
\t\tTRXBLD01 /* FileIOEngine.swift in Sources */ = {isa = PBXBuildFile; fileRef = TRXENG01; };
\t\tTRXBLD02 /* PatchZipConverter.swift in Sources */ = {isa = PBXBuildFile; fileRef = TRXENG02; };
\t\tTRXTBL01 /* FileIOEngineTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = TRXTST01; };
\t\tTRXTBL02 /* PatchZipConverterTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = TRXTST02; };
"""
text = text.replace('/* Begin PBXBuildFile section */', '/* Begin PBXBuildFile section */' + build_files_to_add)

# Add file references in PBXFileReference section
file_refs_to_add = """
\t\tTRXENG01 /* FileIOEngine.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FileIOEngine.swift; sourceTree = "<group>"; };
\t\tTRXENG02 /* PatchZipConverter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PatchZipConverter.swift; sourceTree = "<group>"; };
\t\tTRXTST00 /* TororoxTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = TororoxTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
\t\tTRXTST01 /* FileIOEngineTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FileIOEngineTests.swift; sourceTree = "<group>"; };
\t\tTRXTST02 /* PatchZipConverterTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PatchZipConverterTests.swift; sourceTree = "<group>"; };
"""
text = text.replace('/* Begin PBXFileReference section */', '/* Begin PBXFileReference section */' + file_refs_to_add)

# Add engine group and TororoxTests group in PBXGroup
groups_to_add = """
\t\tTRXGRP01 /* engine */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tTRXENG01 /* FileIOEngine.swift */,
\t\t\t\tTRXENG02 /* PatchZipConverter.swift */,
\t\t\t);
\t\t\tpath = engine;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tTRXGRP02 /* TororoxTests */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tTRXTST01 /* FileIOEngineTests.swift */,
\t\t\t\tTRXTST02 /* PatchZipConverterTests.swift */,
\t\t\t);
\t\t\tpath = TororoxTests;
\t\t\tsourceTree = "<group>";
\t\t};
"""
text = text.replace('/* Begin PBXGroup section */', '/* Begin PBXGroup section */' + groups_to_add)

# Add engine group to Tororox group's children
text = re.sub(
    r'(3105A401 /\* Tororox \*/ = \{[^}]+children = \()',
    r'\1\n\t\t\t\tTRXGRP01 /* engine */,',
    text
)

# Add TororoxTests to root group children
text = re.sub(
    r'(3105A400 = \{[^}]+children = \()',
    r'\1\n\t\t\t\tTRXGRP02 /* TororoxTests */,',
    text
)

# Add TororoxTests.xctest to Products group
text = re.sub(
    r'(3105A402 /\* Products \*/ = \{[^}]+children = \()',
    r'\1\n\t\t\t\tTRXTST00 /* TororoxTests.xctest */,',
    text
)

# Add build files to Sources build phase of Tororox
text = re.sub(
    r'(3105A700 /\* Sources \*/ = \{[^}]+files = \()',
    r'\1\n\t\t\t\tTRXBLD01 /* FileIOEngine.swift in Sources */,\n\t\t\t\tTRXBLD02 /* PatchZipConverter.swift in Sources */,',
    text
)

# Add TororoxTests Sources build phase
sources_build_phase_tests = """
\t\tTRXPHS01 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tTRXTBL01 /* FileIOEngineTests.swift in Sources */,
\t\t\t\tTRXTBL02 /* PatchZipConverterTests.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
text = text.replace('/* Begin PBXSourcesBuildPhase section */', '/* Begin PBXSourcesBuildPhase section */' + sources_build_phase_tests)

# Add TororoxTests Frameworks and Resources phases if needed
frameworks_phase_tests = """
\t\tTRXPHS02 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
text = text.replace('/* Begin PBXFrameworksBuildPhase section */', '/* Begin PBXFrameworksBuildPhase section */' + frameworks_phase_tests)

resources_phase_tests = """
\t\tTRXPHS03 /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
text = text.replace('/* Begin PBXResourcesBuildPhase section */', '/* Begin PBXResourcesBuildPhase section */' + resources_phase_tests)

# Add PBXTargetDependency & PBXContainerItemProxy
target_proxy = """
/* Begin PBXContainerItemProxy section */
\t\tTRXPRX01 /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 3105A000 /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = 3105A500;
\t\t\tremoteInfo = Tororox;
\t\t};
/* End PBXContainerItemProxy section */

/* Begin PBXTargetDependency section */
\t\tTRXDEP01 /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = 3105A500 /* Tororox */;
\t\t\ttargetProxy = TRXPRX01 /* PBXContainerItemProxy */;
\t\t};
/* End PBXTargetDependency section */
"""
text = text.replace('/* Begin PBXNativeTarget section */', target_proxy + '\n/* Begin PBXNativeTarget section */')

# Add TororoxTests PBXNativeTarget
native_target_tests = """
\t\tTRXTAR01 /* TororoxTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = TRXCFG00 /* Build configuration list for PBXNativeTarget "TororoxTests" */;
\t\t\tbuildPhases = (
\t\t\t\tTRXPHS01 /* Sources */,
\t\t\t\tTRXPHS02 /* Frameworks */,
\t\t\t\tTRXPHS03 /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\tTRXDEP01 /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = TororoxTests;
\t\t\tproductName = TororoxTests;
\t\t\tproductReference = TRXTST00 /* TororoxTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t};
"""
text = text.replace('/* End PBXNativeTarget section */', native_target_tests + '/* End PBXNativeTarget section */')

# Add TororoxTests to targets list in PBXProject
text = re.sub(
    r'(3105A000 /\* Project object \*/ = \{[^}]+targets = \([^)]+)',
    r'\g<1>\t\t\t\tTRXTAR01 /* TororoxTests */,\n',
    text
)

# Add XCBuildConfiguration and XCConfigurationList for TororoxTests
test_configs = """
\t\tTRXCFG01 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.apple.mobile.TororoxTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Tororox.app/Tororox";
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\tTRXCFG02 /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.apple.mobile.TororoxTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Tororox.app/Tororox";
\t\t\t};
\t\t\tname = Release;
\t\t};
"""
text = text.replace('/* Begin XCBuildConfiguration section */', '/* Begin XCBuildConfiguration section */' + test_configs)

test_config_list = """
\t\tTRXCFG00 /* Build configuration list for PBXNativeTarget "TororoxTests" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tTRXCFG01 /* Debug */,
\t\t\t\tTRXCFG02 /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
"""
text = text.replace('/* Begin XCConfigurationList section */', '/* Begin XCConfigurationList section */' + test_config_list)

dest_path = os.path.join('Tororox.xcodeproj', 'project.pbxproj')
with open(dest_path, 'w', encoding='utf-8') as f:
    f.write(text)

print('Generated Tororox.xcodeproj/project.pbxproj successfully. Length:', len(text))
