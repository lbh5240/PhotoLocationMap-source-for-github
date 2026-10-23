"""Deterministic dependency-free Xcode project writer. Run on Windows or macOS."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = {}
def obj(name, body):
    key = ident(name); objects[key] = body; return key
def ids(values): return '(' + ', '.join(values) + ',)'

groups, file_ids, build_ids = [], {}, {}
for folder in ['iOS', 'UITests']:
    children = []
    for path in sorted((ROOT/folder).rglob('*')):
        if not path.is_file(): continue
        relative = path.relative_to(ROOT).as_posix()
        kind = 'sourcecode.swift' if path.suffix == '.swift' else ('text.plist.xml' if path.suffix in ['.plist', '.entitlements', '.xcprivacy'] else 'text')
        fid = obj('file:'+relative, f'isa = PBXFileReference; lastKnownFileType = {q(kind)}; path = {q(relative)}; sourceTree = SOURCE_ROOT;')
        file_ids[relative] = fid; children.append(fid)
        if path.suffix == '.swift' or path.name in ['PrivacyInfo.xcprivacy', 'ThirdPartyNotices.txt']:
            build_ids[relative] = obj('build:'+relative, f'isa = PBXBuildFile; fileRef = {fid};')
    groups.append(obj('group:'+folder, f'isa = PBXGroup; children = {ids(children)}; name = {folder}; sourceTree = "<group>";'))
product = obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = ZORACamera.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ZORACameraUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = {ids([product,test_product])}; name = Products; sourceTree = "<group>";')
main_group = obj('main-group', f'isa = PBXGroup; children = {ids(groups+[products])}; sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
dep = obj('core-dependency', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = ZoraCore;')
link = obj('core-link', f'isa = PBXBuildFile; productRef = {dep};')
source = obj('app-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids([b for p,b in build_ids.items() if p.startswith("iOS/") and p.endswith(".swift")])}; runOnlyForDeploymentPostprocessing = 0;')
resources = obj('app-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {ids([build_ids["iOS/PrivacyInfo.xcprivacy"], build_ids["iOS/ThirdPartyNotices.txt"]])}; runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('app-frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {ids([link])}; runOnlyForDeploymentPostprocessing = 0;')
test_sources = obj('test-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids([b for p,b in build_ids.items() if p.startswith("UITests/")])}; runOnlyForDeploymentPostprocessing = 0;')
test_frameworks = obj('test-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
app_id, test_id, project_id = ident('app-target'), ident('ui-target'), ident('project')
proxy = obj('target-proxy', f'isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {app_id}; remoteInfo = ZORACamera;')
target_dep = obj('ui-target-dependency', f'isa = PBXTargetDependency; target = {app_id}; targetProxy = {proxy};')

def configs(label, settings):
    result = []
    for mode in ['Debug', 'Release']:
        opts = dict(settings)
        if label == 'project':
            opts.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
            if mode == 'Debug': opts['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        body = ' '.join(f'{k} = {q(v)};' for k,v in opts.items())
        result.append(obj(label+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {mode};'))
    return obj(label+'-config-list', f'isa = XCConfigurationList; buildConfigurations = {ids(result)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

common = {'SWIFT_VERSION':'6.0','IPHONEOS_DEPLOYMENT_TARGET':'27.0','SDKROOT':'iphoneos','CLANG_ENABLE_MODULES':'YES','SWIFT_STRICT_CONCURRENCY':'complete','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
project_config = configs('project', common)
app_config = configs('app', {'PRODUCT_BUNDLE_IDENTIFIER':'app.zora.camera','PRODUCT_NAME':'$(TARGET_NAME)', 'INFOPLIST_FILE':'iOS/Info.plist', 'CODE_SIGN_ENTITLEMENTS':'iOS/ZORACamera.entitlements','CODE_SIGN_STYLE':'Automatic','TARGETED_DEVICE_FAMILY':'1,2','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':'3','MARKETING_VERSION':'0.3.0'})
test_config = configs('uitest', {'PRODUCT_BUNDLE_IDENTIFIER':'app.zora.camera.uitests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','TARGETED_DEVICE_FAMILY':'1,2','TEST_TARGET_NAME':'ZORACamera'})
objects[app_id] = f'isa = PBXNativeTarget; buildConfigurationList = {app_config}; buildPhases = {ids([source,frameworks,resources])}; buildRules = (); dependencies = (); name = ZORACamera; packageProductDependencies = {ids([dep])}; productName = ZORACamera; productReference = {product}; productType = "com.apple.product-type.application";'
objects[test_id] = f'isa = PBXNativeTarget; buildConfigurationList = {test_config}; buildPhases = {ids([test_sources,test_frameworks])}; buildRules = (); dependencies = {ids([target_dep])}; name = ZORACameraUITests; productName = ZORACameraUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing";'
objects[project_id] = f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{ {test_id} = {{ TestTargetID = {app_id}; }}; }}; }}; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = {main_group}; productRefGroup = {products}; packageReferences = {ids([package])}; projectDirPath = ""; projectRoot = ""; targets = {ids([app_id,test_id])};'
project_path = ROOT/'ZORACamera.xcodeproj'
project_path.mkdir(exist_ok=True)
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text += '\n'.join(f'{k} = {{ {v} }};' for k,v in objects.items())
text += f'\n}}; rootObject = {project_id}; }}\n'
(project_path/'project.pbxproj').write_text(text, encoding='utf-8')
scheme = project_path/'xcshareddata/xcschemes/ZORACamera.xcscheme'; scheme.parent.mkdir(parents=True,exist_ok=True)
ref = lambda target,name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:ZORACamera.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app_id,'ZORACamera.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test_id,'ZORACameraUITests.xctest')}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_id,'ZORACamera.app')}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_id,'ZORACamera.app')}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''', encoding='utf-8')
print(f'Generated project: {len(objects)} objects, {len(file_ids)} files')
