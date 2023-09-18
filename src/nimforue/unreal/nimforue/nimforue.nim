import ../coreuobject/[uobject, unrealtype, nametypes, package]
import ../core/containers/[unrealstring, map, array]
import nimforuebindings
import std/[strformat, options]
include ../definitions
import ../../codegen/[models,]

import ../../utils/[utils, ueutils]
import ../engine/enginetypes
import std/[typetraits, tables, strutils, sequtils, sugar]


#This file contains logic on top of ue types that it isnt necessarily bind 



func isNimClass*(cls:UClassPtr) : bool = cls.hasMetadata(NimClassMetadataKey)
   

proc markAsNimClass*(cls:UClassPtr) = cls.setMetadata(NimClassMetadataKey, "true")

#not sure if I should make a specific file for object extensions that are outside of the bindings
proc getDefaultObjectFromClassName*(clsName:FString) : UObjectPtr {.exportcpp.} = 
  let cls = getClassByName(clsName)
  if cls.isNotNil:
    result = cls.getDefaultObject()

proc removeFunctionFromClass*(cls:UClassPtr, fn:UFunctionPtr) =
    cls.removeFunctionFromFunctionMap(fn)
    cls.Children = fn.Next 

proc getFPropsFromUStruct*(ustr:UStructPtr, flags=EFieldIterationFlags.None) : seq[FPropertyPtr] = 
    var xs : seq[FPropertyPtr] = @[]
    var fieldIterator = makeTFieldIterator[FProperty](ustr, flags)
    for it in fieldIterator:
        let prop = it.get()
        xs.add prop
    xs
#This should be an iterator    
proc getFuncsFromClass*(cls:UClassPtr, flags=EFieldIterationFlags.None) : seq[UFunctionPtr] = 
    var xs : seq[UFunctionPtr] = @[]
    var fieldIterator = makeTFieldIterator[UFunction](cls, flags)
    for it in fieldIterator:
        let fn = it.get()
        xs.add fn
    xs


proc getFuncsParamsFromClass*(cls:UClassPtr, flags=EFieldIterationFlags.None) : seq[FPropertyPtr] = 
    cls 
    .getFuncsFromClass(flags)
    .mapIt(it.getFPropsFromUStruct(flags))
    .foldl(a & b, newSeq[FPropertyPtr]())

proc findFunctionByNameIncludingSuper*(cls : UClassPtr, name:FName) : UFunctionPtr = 
  cls.getFuncsFromClass(EFieldIterationFlags.IncludeSuper)
    .filterIt(it.getFName() == name)
    .head()
    .get(nil)
#bound directly so we dont have to compile this with the bindings
# func findFuncByName*(cls : UClassPtr, name:FName) : UFunctionPtr = 
#   cls.getFuncsFromClass()
#     .filterIt(it.getFName() == name)
#     .head()
#     .get(nil)

proc getAllPropsOf*[T : FProperty](ustr:UStructPtr) : seq[ptr T] = 
    ustr.getFPropsFromUStruct()
        .filterIt(castField[T](it).isNotNil())
        .mapIt(castField[T](it))

   
proc getAllPropsWithMetaData*[T : FProperty](ustr:UStructPtr, metadataKey:string) : seq[ptr T] = 
    ustr.getAllPropsOf[:T]()
        .filterIt(it.hasMetaData(metadataKey))

func getModuleRelativePath*(str:UStructPtr) : Option[string] = 
  str
    .getAllPropsWithMetaData[:FProperty]("ModuleRelativePath")
    .head()
    .flatMap((p:FPropertyPtr) => p.getMetaData("ModuleRelativePath").map(m => $m))
  

#it will call super until UObject is reached
iterator getClassHierarchy*(cls:UClassPtr) : UClassPtr = 
    var super = cls
    let uObjCls = staticClass[UObject]()
    while super != uObjCls:
        super = super.getSuperClass()
        yield super

func isBPClass*(cls:UClassPtr) : bool =    
    result = (CLASS_CompiledFromBlueprint.uint32 and cls.classFlags.uint32) != 0
    # UE_Warn &"isBpClass called for {cls.getName() } and result is {result}"
    

func getFirstCppClass*(cls:UClassPtr) : UClassPtr =
    for super in getClassHierarchy(cls):
        if super.isNimClass() or super.isBPClass():
            continue
        return super

proc getPropsWithFlags*(fn:UFunctionPtr, flag:EPropertyFlags) : TArray[FPropertyPtr] = 
    let isIn = (p:FPropertyPtr) => flag in p.getPropertyFlags()
    getFPropertiesFrom(fn).filter(isIn)

proc isOutParam*(prop:FPropertyPtr) : bool = CPF_OutParm in prop.getPropertyFlags()


proc callStaticUFunction*(clsName, fnName: string, args:pointer): bool = 
  #dynamically calls a ufunction
  #args is Params. See exported for an example  
  let fnName = n fnName
  let self {.inject.} = getDefaultObjectFromClassName(clsName)
  if self.isNil():
     false
  else:
    let fn {.inject, used.} = ueCast[UObject](self).getClass().findFuncByName(fnName)
    if fn.isNil():
      false
    else:
      self.processEvent(fn, args)
      true



#this shouldnt be needed when having out in TArray
func asUObjectArray*[T : UObject](arr:TArray[ptr T]): TArray[UObjectPtr] = 
  var xs = makeTArray[UObjectPtr]()
  for x in arr:
    xs.add x
  xs


#Probably these should be repr

func `$`*(prop:FPropertyPtr):string= 

  if prop.isNil(): 
    return "nil"
  let meta = prop.getMetadataMap()
  &"Prop: {prop.getName()} CppType: {prop.getCppType()} Offset: {prop.getOffset()} Flags: {prop.getPropertyFlags()} Metadata: {meta}"


    

func `$`*(fn:UFunctionPtr):string = 
  if fn.isNil(): 
    return "nil"
  
  let metadataMap = fn.getMetadataMap()
  if metadataMap.len() > 0:
    metadataMap.remove(n"Comment")
    metadataMap.remove(n"ToolTip")
  let params = getFPropsFromUStruct(fn).mapIt($it).join("\n\t")
    #PROPS?
  &"""Func: {fn.getName()} Class: {fn.getOuter()} Flags: {fn.functionFlags} Metadata: {metadataMap}
  
  Params: 
    {params}
  """


proc isA[T:FProperty](prop:FPropertyPtr) : bool = tryCastField[T](prop).isSome()
proc asA[T:FProperty](prop:FPropertyPtr) : ptr T = castField[T](prop)
# when WithEditor:
  
proc `$`*(str:UScriptStructPtr) : string = 
  # "hola"
  result = &"ScriptStruct: {str.getName()} \n\t Parent: \n\t Module:{str.getPackage().getModuleName()} \n\t Package:{str.getPackage().getName()} \n\t Struct Flags: {str.structFlags} \n\t Object Flags: {str.getFlags}"
  # result = &"{str} \n\t Metas:"
  # let metas = str.getMetadataMap().toTable()
  # for key, value in metas:
  #   result = &"{str}\n\t\t {key} : {value}"

  # result = &"{str} \n\t Props:"
  # for p in str.getFPropsFromUStruct():
  #   result = &"{str}\n\t\t {p}"
  

proc `$`*(cls:UClassPtr) : string = 
  var str = &"Class: {cls.getName()} \n\t Parent: {cls.getSuperClass().getName()}\n\t Module:{cls.getPackage().getModuleName()} \n\t Package:{cls.getPackage().getName()} \n\t Class Flags: {cls.classFlags} \n\t Object Flags: {cls.getFlags}"
  str = &"{str} \n\t Interfaces:"
  for i in cls.interfaces:
    str = &"{str}\n\t\t {i}"
  str = &"{str} \n\t Metas:"
  let metas = cls.getMetadataMap().toTable()
  for key, value in metas:
    str = &"{str}\n\t\t {key} : {value}"

  str = &"{str} \n\t Props:"
  for p in cls.getFPropsFromUStruct():
    str = &"{str}\n\t\t {p}"
    
  str = &"{str} \n\t Funcs:"
  let funcs = cls.getFuncsFromClass()
  for f in funcs:
    str = &"{str}\n\t\t {f}"
  str

proc `$`*(obj:UObjectPtr) : string = 
  if obj.isNil(): return "nil"
  # UE_Warn getStackTrace()
  obj.getName()
  
proc repr*(obj:UObjectPtr) : string = 
    if obj.isNil(): return "nil"
    var str = &"\n {obj.getName()}:\n\t"
    let props = obj.getClass().getFPropsFromUStruct(IncludeSuper)
    for p in props:
        #Only UObjects vals for now:
        
        if p.isA[:FObjectPtrProperty]():
            let valPtr = someNil getPropertyValuePtr[UObjectPtr](p, obj)
            let val = valPtr.map(p=>tryUECast[UObject](p[])).flatten()
            if val.isSome():
                str = str & &"{p.getName()}: \n\t {val.get().getName()}\n\t"
        elif p.isA[:FBoolProperty]():
            let val = getValueFromBoolProp(p, obj)
            str = str & &"{p.getName()}: {val}\n\t"
        elif p.isA[:FStrProperty]():
            let val = getPropertyValuePtr[FString](p, obj)[]
            str = str & &"{p.getName()}: {val}\n\t"
        elif p.isA[:FNameProperty]():
            let val = getPropertyValuePtr[FName](p, obj)[]
            str = str & &"{p.getName()}: {val}\n\t"
        elif p.isA[:FClassProperty]():
            let val = getPropertyValuePtr[UClassPtr](p, obj)[]
            str = str & &"{p.getName()}: {val.getName()}\n\t"
        # elif p.isA[FUinProperty]():
    str

func makeUEMetadata*(name:FName, value:FString) : UEMetadata = 
    makeUEMetadata($n, value)