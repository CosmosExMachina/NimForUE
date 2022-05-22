#HERE ALL METHODS USES TO COMUNICATE VIA FFI WITH UNREAL
#ALSO export the UEConfig type to Cpp (not sure if it has to be done in the other project)

{.emit: """/*INCLUDESECTION*/
#include "Definitions.NimForUE.h"
#include "Definitions.NimForUEBindings.h"
#include "UObject/UnrealType.h"
""".}

import unreal/coreuobject/uobject
import unreal/core/containers/unrealstring
import unreal/nimforue/nimForUEBindings
import macros/[ffi, uebind]
import strformat



proc saySomething(obj:UObjectPtr, msg:FString) : void {.uebind.}
proc testMultipleParams(obj:UObjectPtr, msg:FString,  num:int) : FString {.uebind.}

proc boolTestFromNimAreEquals(obj:UObjectPtr, numberStr:FString, number:int, boolParam:bool) : bool {.uebind.}

proc setColorByStringInMesh(obj:UObjectPtr, color:FString): void  {.uebind.}
#define on config.nims
const genFilePath* {.strdefine.} : string = ""

#it's here for ref
proc testCallUFuncOnWrapper(executor:UObjectPtr; str:FString; n:int) : FString    =     
    type Params = object 
            str: FString
            n: int
            toReturn: FString #Output paramaeters 
        
    var parms = Params(str: str, n: n)
    var funcName = makeFString("TestMultipleParams")
    callUFuncOn(executor, funcName, parms.addr, parms.toReturn.addr)
    return parms.toReturn


{.push exportc, cdecl, dynlib.} 
 
proc testCallUFuncOn(obj:pointer) : void  {.ffi:genFilePath}  = 

    let executor = cast[UObjectPtr](obj)

    let msg = testMultipleParams(executor, "hola", 34)
    executor.saySomething(msg)

    executor.setColorByStringInMesh("(R=1.0 ,G=0,B=1,A=1)") 
    if executor.boolTestFromNimAreEquals("5", 5, true):
        executor.saySomething("true")
    else:
        executor.saySomething("false")

   
{.pop.}

