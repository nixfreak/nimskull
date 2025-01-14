## This module contains the definitions for error reporting inside
## VM execution.
##
## To raise a `VmError` use `raiseVmError`. To override the source
## location where the error is reported to have happened, use the overload
## that takes an additional `TLineInfo`.
##
## `raiseVmError` must not be used outside of VM execution (`rawExecute`)
## nor inside VM code-generation (`vmgen`)

import
  compiler/ast/[
    lineinfos,
  ],
  compiler/front/[
    msgs
  ],
  compiler/vm/vmdef

type VmError* = object of CatchableError
  event*: VmEvent

func raiseVmError*(
  event: sink VmEvent;
  inst:  InstantiationInfo
  ) {.noinline, noreturn.} =
  ## Raises a `VmError`.
  event.instLoc = inst
  raise (ref VmError)(event: event)

# templates below are required as InstantiationInfo isn't captured otherwise

template raiseVmError*(event: VmEvent) =
  ## Raises a `VmError`, using the source code position of the callsite as the
  ## `inst` value.
  raiseVmError(event, instLoc(-2))