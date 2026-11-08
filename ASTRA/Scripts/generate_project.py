#!/usr/bin/env python3
"""Generate a dependency-free, deterministic Xcode project using standard PBX objects."""
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quote(value): return json.dumps(value, ensure_ascii=False)
objects = {}
def add(name, value): objects[uid(name)] = value; return uid(name)
files = sorted(list((ROOT / 'App').glob('*.swift')) + list((ROOT / 'App').glob('*.metal')) + list((ROOT / 'Core').glob('*.cpp')) + list((ROOT / 'Core').glob('*.mm')))
sources, children = [], []
for file in files:
    rel = file.relative_to(ROOT).as_posix()
    typ = 'sourcecode.swift' if file.suffix == '.swift' else ('sourcecode.metal' if file.suffix == '.metal' else ('sourcecode.cpp.objcpp' if file.suffix == '.mm' else 'sourcecode.cpp.cpp'))
    ref = add(rel, f'{{isa = PBXFileReference; lastKnownFileType = {typ}; path = {quote(rel)}; sourceTree = SOURCE_ROOT; }}')
    children.append(ref)
    sources.append(add('build:'+rel, f'{{isa = PBXBuildFile; fileRef = {ref}; }}'))
resources = []
for rel,typ in [('App/Assets.xcassets','folder.assetcatalog'),('App/PrivacyInfo.xcprivacy','text.xml')]:
    ref = add(rel, f'{{isa = PBXFileReference; lastKnownFileType = {typ}; path = {quote(rel)}; sourceTree = SOURCE_ROOT; }}')
    children.append(ref); resources.append(add('build:'+rel, f'{{isa = PBXBuildFile; fileRef = {ref}; }}'))
for rel in ['App/Info.plist', 'App/ASTRA-Bridging-Header.h', 'Core/AstroCore.hpp', 'Core/AstroBridge.h']:
    children.append(add(rel,f'{{isa = PBXFileReference; path = {quote(rel)}; sourceTree = SOURCE_ROOT; }}'))
frameworks = []
for framework in ['Foundation','SwiftUI','UIKit','CoreImage','ImageIO','UniformTypeIdentifiers','Photos','PhotosUI','CoreTransferable']:
    ref = add(framework, f'{{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {framework}.framework; path = System/Library/Frameworks/{framework}.framework; sourceTree = SDKROOT; }}')
    children.append(ref);frameworks.append(add('link:'+framework,f'{{isa = PBXBuildFile; fileRef = {ref}; }}'))
product = add('product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = ASTRA.app; sourceTree = BUILT_PRODUCTS_DIR; }')
ui_product = add('ui-product','{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ASTRAUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }')
ui_ref = add('ui-ref','{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UITests/StackFlowTests.swift; sourceTree = SOURCE_ROOT; }')
children.append(ui_ref)
products = add('products',f'{{isa = PBXGroup; name = Products; children = ({product},{ui_product},); sourceTree = "<group>"; }}')
main = add('main',f'{{isa = PBXGroup; children = ({",".join(children+[products])},); sourceTree = "<group>"; }}')
def phase(name,isa,items): return add(name,f'{{isa = {isa}; buildActionMask = 2147483647; files = ({",".join(items)},); runOnlyForDeploymentPostprocessing = 0; }}')
phases = [phase('sources','PBXSourcesBuildPhase',sources),phase('frameworks','PBXFrameworksBuildPhase',frameworks),phase('resources','PBXResourcesBuildPhase',resources)]
def conf(name, settings):
    body = ' '.join(f'{key} = {"(" + ",".join(quote(item) for item in value) + ",)" if isinstance(value, list) else quote(value)};' for key,value in settings.items())
    return add(name, f'{{isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name.split(":")[-1]}; }}')
base = {'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'26.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','CLANG_CXX_LANGUAGE_STANDARD':'c++17','CLANG_CXX_LIBRARY':'libc++','GCC_ENABLE_CPP_EXCEPTIONS':'YES','GCC_WARN_64_TO_32_BIT_CONVERSION':'YES','GCC_WARN_ABOUT_RETURN_TYPE':'YES_ERROR','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
target = {'PRODUCT_NAME':'ASTRA','PRODUCT_BUNDLE_IDENTIFIER':'com.astra.starrynight','INFOPLIST_FILE':'App/Info.plist','GENERATE_INFOPLIST_FILE':'NO','SWIFT_OBJC_BRIDGING_HEADER':'App/ASTRA-Bridging-Header.h','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','MTLLINKER_FLAGS':['-framework','CoreImage'],'MARKETING_VERSION':'0.7.2','CURRENT_PROJECT_VERSION':'11','SUPPORTS_MACCATALYST':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SWIFT_EMIT_LOC_STRINGS':'YES'}
ui_settings = {'PRODUCT_NAME':'ASTRAUITests','PRODUCT_BUNDLE_IDENTIFIER':'com.astra.starrynight.uitests','GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'ASTRA','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic'}
lists = {}
for kind,baseSettings in [('project',base),('target',target),('uitest',ui_settings)]:
    configs=[]
    for mode in ['Debug','Release']:
        settings=dict(baseSettings)
        if kind == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','GCC_OPTIMIZATION_LEVEL':'0' if mode=='Debug' else '3','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'})
            if mode=='Debug':settings.update({'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG','GCC_PREPROCESSOR_DEFINITIONS':'$(inherited) DEBUG=1'})
        configs.append(conf(kind+':'+mode,settings))
    lists[kind]=add(kind+':configlist',f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
native=add('native',f'{{isa = PBXNativeTarget; buildConfigurationList = {lists["target"]}; buildPhases = ({",".join(phases)},); buildRules = (); dependencies = (); name = ASTRA; productName = ASTRA; productReference = {product}; productType = "com.apple.product-type.application"; }}')
ui_build = add('ui-build',f'{{isa = PBXBuildFile; fileRef = {ui_ref}; }}')
ui_sources = phase('ui-sources','PBXSourcesBuildPhase',[ui_build])
ui_proxy = add('ui-proxy',f'{{isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {native}; remoteInfo = ASTRA; }}')
ui_dependency = add('ui-dependency',f'{{isa = PBXTargetDependency; target = {native}; targetProxy = {ui_proxy}; }}')
ui_target = add('ui-target',f'{{isa = PBXNativeTarget; buildConfigurationList = {lists["uitest"]}; buildPhases = ({ui_sources},); buildRules = (); dependencies = ({ui_dependency},); name = ASTRAUITests; productName = ASTRAUITests; productReference = {ui_product}; productType = "com.apple.product-type.bundle.ui-testing"; }}')
project=add('project',f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {ui_target} = {{TestTargetID = {native}; }}; }}; }}; buildConfigurationList = {lists["project"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en,"zh-Hans",Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({native},{ui_target},); }}')
content = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
content += '\n'.join(f'{key} = {value};' for key,value in objects.items())
content += f'\n}}; rootObject = {project}; }}\n'
(ROOT/'ASTRA.xcodeproj/project.pbxproj').write_text(content)
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{native}" BuildableName="ASTRA.app" BlueprintName="ASTRA" ReferencedContainer="container:ASTRA.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="ASTRAUITests.xctest" BlueprintName="ASTRAUITests" ReferencedContainer="container:ASTRA.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{native}" BuildableName="ASTRA.app" BlueprintName="ASTRA" ReferencedContainer="container:ASTRA.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{native}" BuildableName="ASTRA.app" BlueprintName="ASTRA" ReferencedContainer="container:ASTRA.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
(ROOT/'ASTRA.xcodeproj/xcshareddata/xcschemes/ASTRA.xcscheme').write_text(scheme)
print(f'Generated ASTRA.xcodeproj: {len(files)} source files')
