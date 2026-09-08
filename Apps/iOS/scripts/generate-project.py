#!/usr/bin/env python3
"""Generate a small deterministic Xcode project without a global tool dependency."""
from pathlib import Path
import hashlib, json, plistlib
root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(identifier, isa, **values):
    key = uid(identifier); objects[key] = dict(isa=isa, **values); return key

def plist(path, value):
    (root/path).write_bytes(plistlib.dumps(value, sort_keys=False))
base_info = dict(CFBundleDevelopmentRegion='zh_CN', CFBundleExecutable='$(EXECUTABLE_NAME)',
    CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion='6.0',
    CFBundleName='$(PRODUCT_NAME)', CFBundleShortVersionString='$(MARKETING_VERSION)', CFBundleVersion='$(CURRENT_PROJECT_VERSION)',
    SharedAppGroup='$(XDVPN_APP_GROUP)', SharedKeychainGroup='$(AppIdentifierPrefix)$(XDVPN_BUNDLE_ID).shared',
    TunnelProviderID='$(XDVPN_BUNDLE_ID).PacketTunnel')
plist('Configuration/App-Info.plist', dict(base_info, CFBundlePackageType='APPL', CFBundleDisplayName='XD VPN 验证版',
    LSRequiresIPhoneOS=True, UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},
    UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
    NSLocalNetworkUsageDescription='验证你指定的公司内网地址是否可以访问。'))
plist('Configuration/Tunnel-Info.plist', dict(base_info, CFBundlePackageType='XPC!', CFBundleDisplayName='XD VPN 隧道',
    NSExtension=dict(NSExtensionPointIdentifier='com.apple.networkextension.packet-tunnel', NSExtensionPrincipalClass='$(PRODUCT_MODULE_NAME).PacketTunnelProvider')))
entitlements={'com.apple.developer.networking.networkextension':['packet-tunnel-provider'],
    'com.apple.security.application-groups':['$(XDVPN_APP_GROUP)'],
    'keychain-access-groups':['$(AppIdentifierPrefix)$(XDVPN_BUNDLE_ID).shared']}
plist('Configuration/App.entitlements', entitlements)
plist('Configuration/Tunnel.entitlements', entitlements)
# Required-reason API declarations cover elapsed-time metrics and local file metadata.
# Export compliance is applied after upload by the TestFlight pipeline using the team-confirmed declaration.
plist('Configuration/PrivacyInfo.xcprivacy', dict(NSPrivacyTracking=False, NSPrivacyTrackingDomains=[],
    NSPrivacyCollectedDataTypes=[], NSPrivacyAccessedAPITypes=[
        dict(NSPrivacyAccessedAPIType='NSPrivacyAccessedAPICategorySystemBootTime', NSPrivacyAccessedAPITypeReasons=['35F9.1']),
        dict(NSPrivacyAccessedAPIType='NSPrivacyAccessedAPICategoryFileTimestamp', NSPrivacyAccessedAPITypeReasons=['C617.1'])]))
files={}
for folder in ['App','Common','PacketTunnel','OpenConnectAdapter','Configuration']:
    for path in sorted((root/folder).glob('*')):
        if path.is_file() and '.local.' not in path.name:
            relative=str(path.relative_to(root))
            types={'.swift':'sourcecode.swift','.m':'sourcecode.c.objc','.h':'sourcecode.c.h','.xcconfig':'text.xcconfig','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements','.xcprivacy':'text.xml'}
            files[relative]=obj('file:'+relative,'PBXFileReference',lastKnownFileType=types.get(path.suffix,'text'),path=relative,sourceTree='SOURCE_ROOT')
assets=obj('assets','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='Assets.xcassets',sourceTree='SOURCE_ROOT')
app_product=obj('app.product','PBXFileReference',explicitFileType='wrapper.application',path='XDVPN.app',sourceTree='BUILT_PRODUCTS_DIR')
tunnel_product=obj('tunnel.product','PBXFileReference',explicitFileType='wrapper.app-extension',path='PacketTunnel.appex',sourceTree='BUILT_PRODUCTS_DIR')
products=obj('products','PBXGroup',children=[app_product,tunnel_product],name='Products',sourceTree='<group>')
groups=[obj('group:'+folder,'PBXGroup',children=[key for name,key in files.items() if name.startswith(folder+'/')],name=folder,sourceTree='<group>') for folder in ['App','Common','PacketTunnel','OpenConnectAdapter','Configuration']]
main=obj('main','PBXGroup',children=groups+[assets,products],sourceTree='<group>')
def config_list(name, settings, base=False):
    configs=[]
    for flavor in ['Debug','Release']:
        values=dict(settings)
        if flavor=='Debug': values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone',GCC_OPTIMIZATION_LEVEL='0',DEBUG_INFORMATION_FORMAT='dwarf',SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG')
        else: values.update(SWIFT_OPTIMIZATION_LEVEL='-O',DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
        fields=dict(buildSettings=values,name=flavor)
        if base: fields['baseConfigurationReference']=files['Configuration/Base.xcconfig']
        configs.append(obj(name+flavor,'XCBuildConfiguration',**fields))
    return obj(name+'.configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
project_configs=config_list('project',{},True)
def sources(name,prefixes):
    builds=[]
    for path,ref in files.items():
        if path.endswith(('.swift','.m')) and any(path.startswith(prefix+'/') for prefix in prefixes):
            builds.append(obj(name+path,'PBXBuildFile',fileRef=ref))
    return obj(name+'.sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=builds,runOnlyForDeploymentPostprocessing='0')
def privacy_resources(name):
    file=obj(name+'.privacy.build','PBXBuildFile',fileRef=files['Configuration/PrivacyInfo.xcprivacy'])
    return obj(name+'.privacy.resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[file],runOnlyForDeploymentPostprocessing='0')
engine_phase=obj('engine.phase','PBXShellScriptBuildPhase',buildActionMask='2147483647',files=[],inputPaths=[],outputPaths=[],
    alwaysOutOfDate='1',name='Build pinned iOS engine',runOnlyForDeploymentPostprocessing='0',shellPath='/bin/bash',shellScript='"${SRCROOT}/scripts/build-engine.sh" "${PLATFORM_NAME}"\n')
tunnel_settings=dict(PRODUCT_BUNDLE_IDENTIFIER='$(XDVPN_BUNDLE_ID).PacketTunnel',PRODUCT_NAME='$(TARGET_NAME)',
    INFOPLIST_FILE='Configuration/Tunnel-Info.plist',CODE_SIGN_ENTITLEMENTS='Configuration/Tunnel.entitlements',APPLICATION_EXTENSION_API_ONLY='YES',
    SWIFT_OBJC_BRIDGING_HEADER='OpenConnectAdapter/Bridge.h',HEADER_SEARCH_PATHS=['$(inherited)','$(SRCROOT)/.build/engine/$(PLATFORM_NAME)/include'],
    LIBRARY_SEARCH_PATHS=['$(inherited)','$(SRCROOT)/.build/engine/$(PLATFORM_NAME)/lib'],
    OTHER_LDFLAGS=['$(inherited)','-lopenconnect','-lssl','-lcrypto','-lxml2','-lz','-liconv','-framework','NetworkExtension','-framework','Security'],
    LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],SKIP_INSTALL='YES')
tunnel=obj('tunnel.target','PBXNativeTarget',buildConfigurationList=config_list('tunnel',tunnel_settings),buildPhases=[engine_phase,sources('tunnel',['Common','PacketTunnel','OpenConnectAdapter']),privacy_resources('tunnel')],buildRules=[],dependencies=[],name='PacketTunnel',productName='PacketTunnel',productReference=tunnel_product,productType='com.apple.product-type.app-extension')
proxy=obj('proxy','PBXContainerItemProxy',containerPortal=uid('project'),proxyType='1',remoteGlobalIDString=tunnel,remoteInfo='PacketTunnel')
dependency=obj('dependency','PBXTargetDependency',target=tunnel,targetProxy=proxy)
embed_file=obj('embed.file','PBXBuildFile',fileRef=tunnel_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=obj('embed','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[embed_file],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0')
asset_build=obj('assets.build','PBXBuildFile',fileRef=assets)
app_privacy=obj('app.privacy.build','PBXBuildFile',fileRef=files['Configuration/PrivacyInfo.xcprivacy'])
resources=obj('app.resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[asset_build,app_privacy],runOnlyForDeploymentPostprocessing='0')
app_settings=dict(ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',PRODUCT_BUNDLE_IDENTIFIER='$(XDVPN_BUNDLE_ID)',PRODUCT_NAME='$(TARGET_NAME)',INFOPLIST_FILE='Configuration/App-Info.plist',CODE_SIGN_ENTITLEMENTS='Configuration/App.entitlements',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'])
app=obj('app.target','PBXNativeTarget',buildConfigurationList=config_list('app',app_settings),buildPhases=[sources('app',['App','Common']),resources,embed],buildRules=[],dependencies=[dependency],name='XDVPN',productName='XDVPN',productReference=app_product,productType='com.apple.product-type.application')
project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'2660','BuildIndependentTargetsInParallel':'YES'},buildConfigurationList=project_configs,compatibilityVersion='Xcode 14.0',developmentRegion='zh_CN',hasScannedForEncodings='0',knownRegions=['zh_CN','en','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,tunnel])
def serialize(value,indent=0):
    if isinstance(value,dict): return '{\n'+''.join('\t'*(indent+1)+str(k)+' = '+serialize(v,indent+1)+';\n' for k,v in value.items())+'\t'*indent+'}'
    if isinstance(value,list): return '('+', '.join(serialize(v,indent) for v in value)+')'
    return json.dumps(value,ensure_ascii=False)
project_dir=root/'XDVPN.xcodeproj'; project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n')
scheme_dir=project_dir/'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="XDVPN.app" BlueprintName="XDVPN" ReferencedContainer="container:XDVPN.xcodeproj"/>'
(scheme_dir/'XDVPN-iOS.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" shouldAutocreateTestPlan="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated XDVPN.xcodeproj (App + PacketTunnel)')
