import std/[json, jsonutils, os, strutils, genasts, sequtils, strformat, sugar, options]
import ../nimforue/utils/utils
import buildcommon

when defined windows:
  import std/registry

#[
TODO this file does too many things and it's imported from too many places
  It should be split in three files:
    - nimforuedefines.nim
    - nimforueconfig.nim
    - nimforuecppsymbols.nim
]#

# codegen paths
const NimHeadersDir* = "NimHeaders"
const NimHeadersModulesDir* = NimHeadersDir / "Modules"
const BindingsDir* = "src"/"nimforue"/"unreal"/"bindings"
const BindingsImportedDir* = "src"/"nimforue"/"unreal"/"bindings"/"imported"
const BindingsExportedDir* = "src"/"nimforue"/"unreal"/"bindings"/"exported"
const BindingsVMDir* = "src"/"nimforue"/"unreal"/"bindings"/"vm"
const ReflectionDataDir* = "src" / ".reflectiondata"
const ReflectionDataFilePath* = ReflectionDataDir / "ueproject.nim"

const GamePathError* = "Could not find the uproject file."

const MacOsARM* = true #Change this if you want to target x86_64 on mac (TODO autodetect)



when defined(nue) and compiles(gorgeEx("")):

  when defined(windows):
    const ex  = gorgeEx("powershell.exe pwd") 
    const output = $ex[0]
    const PluginDir* = output.split("----")[1].strip().replace("\\src\\buildscripts", "")
  else:
    const ex  = gorgeEx("pwd") 
    const output = $ex[0]
    const PluginDir* = output.strip().replace("/src/buildscripts", "")

else:
  const PluginDir* {.strdefine.} = ""#Defined in switches. Available for all targets (Hots, Guest..)


proc getGamePathFromGameDir*() : string =
  let gameDir = absolutePath(PluginDir/".."/"..", PluginDir)
  walkDir(gameDir)
    .toSeq    
    .filterIt(it[1].endsWith(".uproject"))
    .mapIt(it[1])
    .head()
    .get(GamePathError)
  # (gameDir / "*.uproject").walkFiles.toSeq().head().get(GamePathError)


# https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Projects/FProjectDescriptor/EngineAssociation?application_version=5.4
# engineAssociation if using a stable version is major.minor version
# for perforce/git users that branch the engine with their games it's blank
# for source builds it's a random guid. On windows this is a registry key
#   "HKEY_CURRENT_USER\Software\Epic Games\Unreal Engine\Builds" which will gives us the source directory
#   The version can be looked up in \Engine\Source\Runtime\Launch\Resources\Version.h

type
  EngineAssociationBlankError* = object of Exception # currently don't support blank engineAssociation (need to find the enginedir, see comments in UEVersion)
  EngineAssociationNonWindowsSourceError* = object of Exception # source builds on non-windows platform not supported (how do we get the engine source path?)

var retrievedUEVersion:float = -1f; # store the engine version after we look it up from the uproject using UEVersion() below

proc UEVersion*() : float = #defers the execution until it's needed  
  when defined(nimsuggest) or defined(nimcheck): return 5.2 #Does really matter as it doesnt include anything
  elif defined(android): return 5.3 #TODO do not hardcode this
  elif defined nimvm:
    return 0.0
  else:
    if retrievedUEVersion < 0f:
      let gameDir: string = absolutePath(PluginDir/".."/"..")
      let uprojectFile = getGamePathFromGameDir()

      let engineAssociation = readFile(uprojectFile).parseJson()["EngineAssociation"].getStr()
      try:
        retrievedUEVersion = parseFloat(engineAssociation)
      except ValueError:
        if engineAssociation.len > 0:
          when defined windows:
            let registryPath = "SOFTWARE\\Epic Games\\Unreal Engine\\Builds"
            var engineDir = getUnicodeValue(registryPath, engineAssociation, HKEY_CURRENT_USER)
            var versionFilePath = engineDir / "Engine/Source/Runtime/Launch/Resources/Version.h"
            var
              major:int = 0
              minor:int = 0
              majorFound = false

            for line in versionFilePath.lines:
              if not majorFound and line.contains "ENGINE_MAJOR_VERSION":
                major = parseInt(line[^1..^1])
                majorFound = true
              elif line.contains "ENGINE_MINOR_VERSION":
                minor = parseInt(line[^1..^1])
                break
            retrievedUEVersion = parseFloat($major & "." & $minor)
          else:
            raise newException(EngineAssociationNonWindowsSourceError, "EngineAssociation for source builds on non-windows platform unsupported.")
        else:
            raise newException(EngineAssociationBlankError, "EngineAssociation in uproject is blank and unsupported.")
    return retrievedUEVersion


proc MacPlatformDir*(): string =
  if MacOsARM and UEVersion() >= 5.2:
    "Mac/arm64"
  else:
    "Mac/x86_64"

proc WinPlatformDir*(): string =
  if UEVersion() >= 5.2: #Seems they introduced ARM win support in 5.2
    "Win64/x64"
  else:
    "Win64"
  

when defined windows:
  proc tryGetEngineAndGameDir*() : Option[(string, string)] =
    try:
      #We assume we are inside the game plugin folder when no json is available
      let gameDir = absolutePath(PluginDir/".."/"..")
      let uprojectFile = getGamePathFromGameDir()
      let engineAssociation = readFile(uprojectFile).parseJson()["EngineAssociation"].getStr()
      var engineDir:string
      try:
        let fversion = parseFloat(engineAssociation)
        let registryPath = "SOFTWARE\\EpicGames\\Unreal Engine\\" & $fversion
        engineDir = getUnicodeValue(registryPath, "InstalledDirectory", HKEY_LOCAL_MACHINE)
      except ValueError:
        if engineAssociation.len > 0:
          when defined windows:
            let registryPath = "SOFTWARE\\Epic Games\\Unreal Engine\\Builds"
            engineDir = getUnicodeValue(registryPath, engineAssociation, HKEY_CURRENT_USER)
          else:
            raise newException(EngineAssociationNonWindowsSourceError, "EngineAssociation for source builds on non-windows platform unsupported.")
        else:
            raise newException(EngineAssociationBlankError, "EngineAssociation in uproject is blank and unsupported.")

      some (engineDir / "Engine", gameDir)
    except:
      log "Could not find the game path. Please set the game path in the json file."
      log getCurrentExceptionMsg()
      none[(string, string)]()
else:
  proc tryGetEngineAndGameDir*() : Option[(string, string)] = 
     let gameDir = absolutePath(PluginDir/".."/"..")
     some ("", gameDir)

#Dll output paths for the uclasses the user generates
const OutputHeader* {.strdefine.} = ""
#[
The file is created for first time in from this file during compilation
Since UBT has to set some values on it, it does so through the FFI 
and then Saves it back to the json file. That's why we try to load it first before creating it.
]#


type NimForUEConfig* = object 
  engineDir* : string #Set by UBT
  gameDir* : string
  targetConfiguration* : TargetConfiguration #Sets by UBT (Development, Build)
  targetPlatform* : TargetPlatform #Sets by UBT
  withEditor* : bool
  # currentCompilation* : int 
  #WithEditor? 
  #DEBUG?

func getConfigFileName(): string = 
  when defined macosx:
    return "NimForUE.mac.json"
  when defined windows:
    return "NimForUE.win.json"

#when saving outside of nim set the path to the project
proc saveConfig*(config:NimForUEConfig) =
  let ueConfigPath = PluginDir / getConfigFileName()
  var json = toJson(config)
  writeFile(ueConfigPath, json.pretty())

proc createConfigFromDirs(engineDir, gameDir:string) : NimForUEConfig = 
  let defaultPlatform = when defined(windows): Win64 else: Mac
  NimForUEConfig(engineDir: engineDir, gameDir: gameDir, withEditor:true, targetConfiguration: Development, targetPlatform: defaultPlatform)

proc getOrCreateNUEConfig*() : NimForUEConfig = 
  let ueConfigPath = PluginDir / getConfigFileName()
  if fileExists ueConfigPath:
    let json = readFile(ueConfigPath).parseJson()
    return json.to(NimForUEConfig)
  let conf = 
    tryGetEngineAndGameDir()
      .map(d=>createConfigFromDirs(d[0], d[1]))

  if conf.isSome():
    conf.get().saveConfig()
    return conf.get()

  NimForUEConfig()


proc getNimForUEConfig*(): NimForUEConfig = 
  var config = getOrCreateNUEConfig()

  let configErrMsg = "Please check " & getConfigFileName() & " for missing: "
  doAssert(config.engineDir.dirExists(), configErrMsg & " engineDir")
  doAssert(config.gameDir.dirExists(), configErrMsg & " gameDir")
  config.engineDir = config.engineDir.normalizedPath().normalizePathEnd()
  config.gameDir = config.gameDir.normalizedPath().normalizePathEnd()

  #Rest of the fields are sets by UBT
  config.saveConfig()
  config


#PATHS. The can be set at compile time

#Make sure correct paths are set (Mac vs Wind)
#CREATE AND SAVE BEFORE RETURNING

# when defined(nue):
  # let config = getOrCreateNUEConfig("G:\\NimForUEDemov2\\NimForUEDemov2\\Plugins\\NimForUE")
# else:
#   const PluginDir* {.strdefine.} = ""#Defined in switches. Available for all targets (Hots, Guest..)



let
  ueLibsDir = PluginDir/"Binaries"/"nim"/"ue" #THIS WILL CHANGE BASED ON THE CURRENT CONF
  NimForUELibDir* = ueLibsDir.normalizePathEnd()  
  GenFilePath* = PluginDir / "src" / "hostnimforue"/"ffigen.nim"

proc HostLibPath*(): string = ueLibsDir / getFullLibName("hostnimforue")
proc GameLibPath*(): string = ueLibsDir / getFullLibName("game")

proc NimGameDir*() :string = getOrCreateNUEConfig().gameDir / "NimForUE" #notice this is a proc so it's lazy loaded
proc GamePath*() : string = getGamePathFromGameDir()
proc GameName*() : string = GamePath().split(PathSeparator)[^1].split(".")[0]
#TODO we need to make it accesible from game/guest at compile time
when defined(nue):
  let WithEditor* = getOrCreateNUEConfig().withEditor 
  doAssert(GamePath() != GamePathError, &"Config file error: The uproject file could not be found in {getOrCreateNUEConfig().gameDir}. Please check that 'gameDir' points to the directory containing your uproject in '{PluginDir / getConfigFileName()}'.")

else:
  const WithEditor* {.booldefine.} = true


template codegenDir(fname, constName: untyped): untyped =
  proc fname*(config: NimForUEConfig): string =
    PluginDir / constName

codegenDir(nimHeadersDir, NimHeadersDir)
codegenDir(nimHeadersModulesDir, NimHeadersModulesDir)
codegenDir(bindingsDir, BindingsDir)
codegenDir(bindingsImportedDir, BindingsImportedDir)
codegenDir(bindingsExportedDir, BindingsExportedDir)
codegenDir(reflectionDataDir, ReflectionDataDir)
codegenDir(reflectionDataFilePath, ReflectionDataFilePath)


proc getUEHeadersIncludePaths*(conf:NimForUEConfig) : seq[string] =
  let platformDir = if conf.targetPlatform == Mac: MacPlatformDir() else:  WinPlatformDir()
  let confDir = $ conf.targetConfiguration
  let engineDir = conf.engineDir
  let pluginDir = PluginDir
  let enginePluginDir = engineDir/"Plugins"#\EnhancedInput\Source\EnhancedInput\Public\EnhancedPlayerInput.h

  let unrealFolder = if conf.withEditor: "UnrealEditor" else: "UnrealGame"

  let pluginDefinitionsPaths = pluginDir / "Intermediate" / "Build" / platformDir / unrealFolder / confDir  #Notice how it uses the TargetPlatform, The Editor?, and the TargetConfiguration
  let nimForUEIntermediateHeaders = pluginDir / "Intermediate" / "Build" / platformDir / unrealFolder / "Inc" / "NimForUE"
  let nimForUEBindingsHeaders =  pluginDir / "Source/NimForUEBindings/Public/"
  let nimForUEAutoBindingsHeaders =  pluginDir / "Source/NimForUEAutoBindings/Public/"
  let nimForUEBindingsIntermediateHeaders = pluginDir / "Intermediate" / "Build" / platformDir / unrealFolder / "Inc" / "NimForUEBindings"
  let nimForUEEditorHeaders =  pluginDir / "Source/NimForUEEditor/Public/"
  let nimForUEEditorIntermediateHeaders = pluginDir / "Intermediate" / "Build" / platformDir / unrealFolder / "Inc" / "NimForUEEditor"

  let essentialHeaders = @[
    pluginDefinitionsPaths / "NimForUE",
    pluginDefinitionsPaths / "NimForUEBindings",
    nimForUEIntermediateHeaders,
    nimForUEBindingsHeaders,
    nimForUEBindingsIntermediateHeaders,
    nimForUEAutoBindingsHeaders,
    #notice this shouldn't be included when target <> Editor
    nimForUEEditorHeaders,
    nimForUEEditorIntermediateHeaders,

    pluginDir / "NimHeaders",
    engineDir / "Shaders",
    engineDir / "Shaders/Shared",
    engineDir / "Source",
    engineDir / "Source/Runtime",
    engineDir / "Source/Runtime/Engine",
    engineDir / "Source/Runtime/Engine/Public",
    engineDir / "Source/Runtime/Engine/Public/Rendering",
    engineDir / "Source/Runtime/Engine/Classes",
    engineDir / "Source/Runtime/Engine/Classes/Engine",
    engineDir / "Source/Runtime/Net/Core/Public",
    engineDir / "Source/Runtime/Net/Core/Classes",
    engineDir / "Source/Runtime/InputCore/Classes"
  ]

  let editorHeaders = @[
    engineDir / "Source/Editor",
    engineDir / "Source/Editor/UnrealEd",
    engineDir / "Source/Editor/UnrealEd/Classes",
    engineDir / "Source/Editor/UnrealEd/Classes/Settings"
    
  ]

  proc getEngineRuntimeIncludePathFor(engineFolder, moduleName: string) : string = engineDir / "Source" / engineFolder / moduleName / "Public"
  proc getEngineRuntimeIncludeClassesPathFor(engineFolder, moduleName: string) : string = engineDir / "Source" / engineFolder / moduleName / "Classes"
  proc getEngineIntermediateIncludePathFor(moduleName:string) : string = engineDir / "Intermediate/Build" / platformDir / unrealFolder / "Inc" / moduleName
  proc getEnginePluginModule(moduleName:string) : string = enginePluginDir / moduleName / "Source" / moduleName / "Public"
  proc getEngineRuntimePluginModule(moduleName:string) : string = enginePluginDir / "Runtime" / moduleName / "Source" / moduleName / "Public"
  proc getEngineExperimentalPluginModule(moduleName:string) : string = enginePluginDir / "Experimental" / moduleName / "Source" / moduleName / "Public"


  let runtimeModules = @["CoreUObject", "Core", "TraceLog", "Launch", "ApplicationCore", 
      "Projects", "Json", "PakFile", "RSA", "RenderCore",
      "NetCore", "CoreOnline", "PhysicsCore", "Experimental/Chaos", 
      "SlateCore", "Slate", "TypedElementFramework", "Renderer", "AnimationCore",
      "ClothingSystemRuntimeInterface", "SandboxFile", "NetworkFileSystem",
      "Experimental/Interchange/Core", "UMG", "Slate", "SlateCore",
      "Experimental/ChaosCore", "InputCore", "RHI", "AudioMixerCore", "AssetRegistry", 
      "DeveloperSettings", "AIModule"
      ]

  let developerModules = @["DesktopPlatform", 
  "ToolMenus", "TargetPlatform", "SourceControl", 
  "DeveloperToolSettings",
  "Localization"]
  let intermediateGenModules = @["NetCore", "Engine", "PhysicsCore", "AssetRegistry", 
    "UnrealEd", "ClothingSystemRuntimeInterface",  "EditorSubsystem", "InterchangeCore",
    "TypedElementFramework","Chaos", "ChaosCore", "EditorStyle", "EditorFramework",
    "Localization", "DeveloperToolSettings", "Slate",
    "InputCore", "DeveloperSettings", "SlateCore", "ToolMenus"]
  let editorModules = @["UnrealEd", "PropertyEditor", 
  "EditorStyle", "EditorSubsystem","EditorFramework",
  
  ]

  var enginePlugins:seq[string]
  var engineExperimentalPlugins:seq[string] = newSeq[string]()
  if UEVersion() >= 5.4:
    enginePlugins = @["EnhancedInput", "PCG"]
  else:
    enginePlugins = @["EnhancedInput"]
    engineExperimentalPlugins = @["PCG"]

  let engineRuntimePlugins = @["GameplayAbilities"]

#Notice the header are not need for compiling the dll. We use a PCH. They will be needed to traverse the C++
  let moduleHeaders = 
    runtimeModules.map(module=>getEngineRuntimeIncludePathFor("Runtime", module)) & 
    developerModules.map(module=>getEngineRuntimeIncludePathFor("Developer", module)) & 
    developerModules.map(module=>getEngineRuntimeIncludeClassesPathFor("Developer", module)) & #if it starts to complain about the lengh of the cmd line. Optimize here
    editorModules.map(module=>getEngineRuntimeIncludePathFor("Editor", module)) & 
    intermediateGenModules.map(module=>getEngineIntermediateIncludePathFor(module)) &
    enginePlugins.map(module=>getEnginePluginModule(module)) & 
    engineRuntimePlugins.map(module=>getEngineRuntimePluginModule(module)) &
    engineExperimentalPlugins.map(module=>getEngineExperimentalPluginModule(module))

  (essentialHeaders & moduleHeaders & editorHeaders).map(path => path.normalizedPath().normalizePathEnd())



proc getUESymbols*(conf: NimForUEConfig): seq[string] =
  let platformDir = if conf.targetPlatform == Mac: MacPlatformDir() else: WinPlatformDir()
  let confDir = $conf.targetConfiguration
  let engineDir = conf.engineDir
  let pluginDir = PluginDir
  let unrealFolder = if conf.withEditor: "UnrealEditor" else: "UnrealGame"
  proc getObjFiles(dir: string, moduleName:string) : seq[string] = 
    #useful for non editor builds. Some modules are split
    # let objFiles = walkFiles(dir/ &"Module.{moduleName}*.cpp.obj").toSeq()
    # let objFiles = walkFiles(dir/ &"*.obj").toSeq()
    # echo &"objFiles for {moduleName} in {dir}: {objFiles}"
    
    # objFiles
    @[]

  #We only support Debug and Development for now and Debug is Windows only
  let suffix = if conf.targetConfiguration == Debug : "-Win64-Debug" else: "" 
  proc getEngineRuntimeSymbolPathFor(prefix, moduleName:string): seq[string] =  
    
    when defined windows:
      let dir =  engineDir / "Intermediate/Build" / platformDir / unrealFolder / confDir / moduleName 
      if conf.withEditor:
        @[dir / &"{prefix}-{moduleName}{suffix}.lib"]
      else:
        getObjFiles(dir, moduleName)
       
    elif defined macosx:
      let platform = $conf.targetPlatform #notice the platform changed for the symbols (not sure how android/consoles/ios will work)
      @[engineDir / "Binaries" / platform / &"{prefix}-{moduleName}.dylib"]
#E:\unreal_sources\5.1Launcher\UE_5.1\Engine\Plugins\EnhancedInput\Intermediate\Build\Win64\UnrealEditor\Development\EnhancedInput
  proc getEnginePluginSymbolsPathFor(prefix,  moduleName:string): seq[string] =  
      when defined windows:
        let dir = engineDir / "Plugins" / moduleName / "Intermediate/Build" / platformDir / unrealFolder / confDir / moduleName 
        if conf.withEditor:
          @[dir / &"{prefix}-{moduleName}{suffix}.lib"]
        else:
          getObjFiles(dir, moduleName)

      elif defined macosx:
        let platform = $conf.targetPlatform #notice the platform changed for the symbols (not sure how android/consoles/ios will work)
        @[engineDir / "Plugins" / moduleName / "Binaries" / platform / &"{prefix}-{moduleName}.dylib"]

  #engineFolder is Runtime, Experimental etc.
  proc getEnginePluginSymbolsPathFor(prefix,  engineFolder, moduleName:string): seq[string] =  
      when defined windows:
        let dir = engineDir / "Plugins" / engineFolder / moduleName / "Intermediate/Build" / platformDir / unrealFolder / confDir / moduleName 
        if conf.withEditor:
          @[dir / &"{prefix}-{moduleName}{suffix}.lib"]
        else:
          getObjFiles(dir, moduleName)

      elif defined macosx:
        let platform = $conf.targetPlatform #notice the platform changed for the symbols (not sure how android/consoles/ios will work)
        @[engineDir / "Plugins" / engineFolder  / moduleName / "Binaries" / platform / &"{prefix}-{moduleName}.dylib"]


  proc getNimForUESymbols(): seq[string] = 
    when defined macosx:
      let libpath = pluginDir / "Binaries" / $conf.targetPlatform / "UnrealEditor-NimForUE.dylib"
      let libpathBindings  = pluginDir / "Binaries" / $conf.targetPlatform / "UnrealEditor-NimForUEBindings.dylib"
      #notice this shouldnt be included when target <> Editor
      let libPathEditor  = pluginDir / "Binaries" / $conf.targetPlatform / "UnrealEditor-NimForUEEditor.dylib"
      return @[libPath,libpathBindings, libPathEditor]

    elif defined windows:

      if conf.withEditor:
        #seems like the plugin is still win64?
        let libPath = pluginDir / "Intermediate/Build" / platformDir / unrealFolder / confDir / &"NimForUE/UnrealEditor-NimForUE{suffix}.lib"
        let libPathBindings = pluginDir / "Intermediate/Build" / platformDir / unrealFolder / confDir / &"NimForUEBindings/UnrealEditor-NimForUEBindings{suffix}.lib"
        let libPathAutoBindings = pluginDir / "Intermediate/Build" / platformDir / unrealFolder / confDir / &"NimForUEAutoBindings/UnrealEditor-NimForUEAutoBindings{suffix}.lib"
        let libPathEditor = pluginDir / "Intermediate/Build" / platformDir / unrealFolder / confDir / &"NimForUEEditor/UnrealEditor-NimForUEEditor{suffix}.lib"
        @[libPath,libpathBindings, libPathEditor]
      else:
        let dir = pluginDir / "Intermediate/Build" / platformDir / unrealFolder / confDir 
        let libPath = getObjFiles(dir / "NimForUE", "NimForUE")
        let libPathBindings = getObjFiles(dir / "NimForUEBindings", "NimForUEBindings")
        libPath & libPathBindings


  var enginePlugins = @["EnhancedInput"]
  var experimentalPlugins = newSeq[string]()
  if UEVersion() >= 5.4:
    enginePlugins.add("PCG")
  else:
    experimentalPlugins.add("PCG")


  let modules = @["Core", "CoreUObject", "PhysicsCore", "Engine", 
    "SlateCore","Slate", "UnrealEd", "InputCore", "GameplayTags", "GameplayTasks", 
    "NetCore", "UMG", "AdvancedPreviewScene", "AIModule", "EditorSubsystem"]
  let engineSymbolsPaths  = modules.map(modName=>getEngineRuntimeSymbolPathFor("UnrealEditor", modName)).flatten()
  let enginePluginSymbolsPaths = enginePlugins.map(modName=>getEnginePluginSymbolsPathFor("UnrealEditor", modName)).flatten()
  
 
  let engineRuntimePluginSymbolsPaths = @["GameplayAbilities"].map(modName=>getEnginePluginSymbolsPathFor("UnrealEditor", "Runtime", modName)).flatten()
  let engineExperimentalPluginSymbolsPaths = experimentalPlugins.map(modName=>getEnginePluginSymbolsPathFor("UnrealEditor", "Experimental", modName)).flatten()

  (engineSymbolsPaths & enginePluginSymbolsPaths &  engineRuntimePluginSymbolsPaths & engineExperimentalPluginSymbolsPaths & getNimForUESymbols()).map(path => path.normalizedPath())



#TODO ADD RUNTIME TO THE PATH