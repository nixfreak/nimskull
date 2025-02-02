## Implements the framework for just-in-time (JIT) code-generation
## for the VM. Both procedures and standalone statements/expressions are
## supported as input.
##
## When a procedure is requested that hasn't been processed by the JIT
## compiler, it is transformed, pre-processed (MIR passes applied, etc.), and
## then the bytecode for it is generated. If code generation succeeds, all not-
## already-seen dependencies (like globals, constants, etc.) of the procedure
## are collected, registered with the JIT state, and loaded into the VM's
## execution environment, meaning that the requested procedure can be
## immediately invoked after.
##
## Both compile-time code execution and running NimScript files make use of
## the JIT compiler.

import
  std/[
    tables
  ],
  compiler/ast/[
    ast_types,
    ast_query,
  ],
  compiler/backend/[
    backends,
    cgir,
    cgirgen
  ],
  compiler/mir/[
    mirbridge,
    mirgen,
    mirpasses,
    mirtrees,
    sourcemaps,
  ],
  compiler/modules/[
    magicsys
  ],
  compiler/sem/[
    transf
  ],
  compiler/vm/[
    vmaux,
    vmcompilerserdes,
    vmdef,
    vmgen,
    vmlinker,
    vmmemory,
    vmtypegen
  ],
  experimental/[
    results
  ]

export VmGenResult

type
  JitState* = object
    ## State of the VM's just-in-time compiler that is kept across invocations.
    discovery: DiscoveryData
      ## acts as the source-of-truth regarding what entities exists. All
      ## entities not registered with `discovery` also don't exist in
      ## ``TCtx``
    gen: CodeGenCtx
      ## code generator state

func selectOptions(c: TCtx): set[GenOption] =
  result = {goIsNimvm}
  if cgfAllowMeta in c.flags:
    result.incl goGenTypeExpr

  if c.mode in {emConst, emOptimize, emStaticExpr, emStaticStmt}:
    result.incl goIsCompileTime

func swapState(c: var TCtx, gen: var CodeGenCtx) =
  ## Swaps the values of the fields shared between ``TCtx`` and ``CodeGenCtx``.
  ## This achieves reasonably fast mutable-borrow-like semantics without
  ## resorting to pointers.
  template swap(field: untyped) =
    swap(c.field, gen.field)

  # input parameters:
  swap(graph)
  swap(config)
  swap(mode)
  swap(features)
  swap(module)
  swap(linking)

  # input-output parameters:
  swap(code)
  swap(debug)
  swap(constants)
  swap(typeInfoCache)
  swap(rtti)

proc updateEnvironment(c: var TCtx, data: var DiscoveryData) =
  ## Needs to be called after a `vmgen` invocation and prior to resuming
  ## execution. Allocates and sets up the execution resources required for the
  ## newly gathered dependencies.
  ##
  ## This "commits" to the new dependencies.

  # procedures
  c.functions.setLen(data.procedures.len)
  for i, sym in visit(data.procedures):
    c.functions[i] = initProcEntry(c, sym)

  block: # globals and threadvars
    # threadvars are currently treated the same as normal globals
    var i = c.globals.len
    c.globals.setLen(data.globals.len + data.threadvars.len)

    template alloc(q: Queue[PSym]) =
      for _, sym in visit(q):
        let typ = c.getOrCreate(sym.typ)
        c.globals[i] = c.heap.heapNew(c.allocator, typ)
        inc i

    # order is important here!
    alloc(data.globals)
    alloc(data.threadvars)

  # constants
  c.complexConsts.setLen(data.constants.len)
  for i, sym in visit(data.constants):
    assert sym.ast.kind notin nkLiterals

    let
      typ = c.getOrCreate(sym.typ)
      handle = c.allocator.allocConstantLocation(typ)

    # TODO: strings, seqs and other values using allocation also need to be
    #       allocated with `allocConstantLocation` inside `serialize` here
    c.serialize(sym.ast, handle)

    c.complexConsts[i] = handle


func removeLastEof(c: var TCtx) =
  let last = c.code.len-1
  if last >= 0 and c.code[last].opcode == opcEof:
    # overwrite last EOF:
    assert c.code.len == c.debug.len
    c.code.setLen(last)
    c.debug.setLen(last)

func discoverGlobalsAndRewrite(data: var DiscoveryData, tree: var MirTree,
                               source: var SourceMap, rewrite: bool) =
  ## Scans `tree` for definitions of globals, registers them with the `data`,
  ## and rewrites their definitions into assignments (if `rewrite` is true).

  # scan the body for definitions of globals:
  var i = NodePosition 0
  while i.int < tree.len:
    case tree[i].kind
    of DefNodes:
      if tree[i + 1].kind == mnkGlobal and
         (let g = tree[i+1].sym; sfImportc notin g.flags):
        # found a global definition; register it. Imported ones are
        # ignored -- ``vmgen`` will report an error when the global is
        # accessed
        let s =
          if g.owner.kind in {skVar, skLet, skForVar}:
            g.owner # account for duplicated symbols (see ``transf.freshVar``)
          else:
            g
        data.registerGlobal(s)

      i = findEnd(tree, i) + 1 # skip the def's body
    else:
      inc i

  if rewrite:
    rewriteGlobalDefs(tree, source, patch=true)
  else:
    # the globals still need to be patched
    patchGlobals(tree, source)

func register(linker: var LinkerData, data: DiscoveryData) =
  ## Registers the newly discovered entities in the link table, but doesn't
  ## commit to them yet.
  for i, it in peek(data.procedures):
    linker.symToIndexTbl[it.id] = LinkIndex(i)

  for i, it in peek(data.constants):
    linker.symToIndexTbl[it.id] = LinkIndex(i)

  # first register globals, then threadvars. This order must be the same as
  # the one they're later committed to in
  for i, it in peek(data.globals):
    linker.symToIndexTbl[it.id] = LinkIndex(i)

  for i, it in peek(data.threadvars):
    linker.symToIndexTbl[it.id] = LinkIndex(i)

proc generateMirCode(c: var TCtx, n: PNode;
                     isStmt = false): (MirTree, SourceMap) =
  ## Generates the initial MIR code for a standalone statement/expression.
  if isStmt:
    # we want statements wrapped in a scope, hence generating a proper
    # fragment
    result = generateCode(c.graph, c.module, selectOptions(c), n)
  else:
    var buf: MirBuffer
    generateCode(c.graph, selectOptions(c), n, buf, result[1])
    result[0] = finish(buf)

proc generateIR(c: var TCtx, tree: sink MirTree,
                source: sink SourceMap): Body {.inline.} =
  if tree.len > 0: generateIR(c.graph, c.idgen, c.module, tree, source)
  else:            Body(code: newNode(cnkEmpty))

proc setupRootRef(c: var TCtx) =
  ## Sets up if the ``RootRef`` type for the type info cache. This
  ## is a temporary workaround, refer to the documentation of the
  ## ``rootRef`` field.
  if c.typeInfoCache.rootRef == nil:
    let t = c.graph.getCompilerProc("RootObj")
    # the``RootObj`` type may not be available yet
    if t != nil:
      c.typeInfoCache.initRootRef(c.graph.config, t.typ)

template runCodeGen(c: var TCtx, cg: var CodeGenCtx, b: Body,
                    body: untyped): untyped =
  ## Prepares the code generator's context and then executes `body`. A
  ## delimiting 'eof' instruction is emitted at the end.
  setupRootRef(c)
  swapState(c, cg)
  let info = b.code.info
  let r = body
  cg.gABC(info, opcEof)
  swapState(c, cg)
  r

proc genStmt*(jit: var JitState, c: var TCtx; n: PNode): VmGenResult =
  ## Generates and emits code for the standalone top-level statement `n`.
  c.removeLastEof()

  # `n` is expected to have been put through ``transf`` already
  var (tree, sourceMap) = generateMirCode(c, n, isStmt = true)
  discoverGlobalsAndRewrite(jit.discovery, tree, sourceMap, true)
  applyPasses(tree, sourceMap, c.module, c.config, targetVm)
  discoverFrom(jit.discovery, MagicsToKeep, tree)
  register(c.linking, jit.discovery)

  let
    body = generateIR(c, tree, sourceMap)
    start = c.code.len

  # generate the bytecode:
  let r = runCodeGen(c, jit.gen, body): genStmt(jit.gen, body)

  if unlikely(r.isErr):
    rewind(jit.discovery)
    return VmGenResult.err(r.takeErr)

  updateEnvironment(c, jit.discovery)

  result = VmGenResult.ok: (start: start, regCount: r.get)

proc genExpr*(jit: var JitState, c: var TCtx, n: PNode): VmGenResult =
  ## Generates and emits code for the standalone expression `n`
  c.removeLastEof()

  # XXX: the way standalone expressions are currently handled is going to
  #      be a problem as soon as proper MIR passes need to be run (which
  #      all expect statements). Ideally, dedicated support for
  #      expressions would be removed from the JIT.

  var (tree, sourceMap) = generateMirCode(c, n)
  # constant expression outside of routines can currently also contain
  # definitions of globals...
  # XXX: they really should not, but that's up to sem. Example:
  #
  #        const c = block: (var x = 0; x)
  #
  #     If `c` is defined at the top-level, then `x` is a "global" variable
  discoverGlobalsAndRewrite(jit.discovery, tree, sourceMap, false)
  applyPasses(tree, sourceMap, c.module, c.config, targetVm)
  discoverFrom(jit.discovery, MagicsToKeep, tree)
  register(c.linking, jit.discovery)

  let
    body = generateIR(c, tree, sourceMap)
    start = c.code.len

  # generate the bytecode:
  let r = runCodeGen(c, jit.gen, body): genExpr(jit.gen, body)

  if unlikely(r.isErr):
    rewind(jit.discovery)
    return VmGenResult.err(r.takeErr)

  updateEnvironment(c, jit.discovery)

  result = VmGenResult.ok: (start: start, regCount: r.get)

proc genProc(jit: var JitState, c: var TCtx, s: PSym): VmGenResult =
  c.removeLastEof()

  let body =
    if isCompileTimeProc(s) and not defined(nimsuggest):
      # no need to go through the transformation cache
      transformBody(c.graph, c.idgen, s, s.ast[bodyPos])
    else:
      # watch out! Since transforming a procedure body permanently alters
      # the state of inner procedures, we need to both cache and later
      # retrieve the transformed body for non-compile-only routines or
      # when in suggest mode
      transformBody(c.graph, c.idgen, s, cache = true)

  echoInput(c.config, s, body)
  var (tree, sourceMap) = generateCode(c.graph, s, selectOptions(c), body)
  echoMir(c.config, s, tree)
  # XXX: lifted globals are currently not extracted from the procedure and,
  #      for the most part, behave like normal locals. The call to
  #      ``discoverGlobalsAndRewrite`` plus the MIR -> ``CgNode`` translation
  #      make sure that at least ``vmgen`` doesn't have to be concerned with
  #      that, but eventually it needs to be decided how lifted globals should
  #      work in compile-time and interpreted contexts
  discoverGlobalsAndRewrite(jit.discovery, tree, sourceMap, false)
  applyPasses(tree, sourceMap, s, c.config, targetVm)
  discoverFrom(jit.discovery, MagicsToKeep, tree)
  register(c.linking, jit.discovery)

  let outBody = generateIR(c.graph, c.idgen, s, tree, sourceMap)
  echoOutput(c.config, s, outBody)

  # generate the bytecode:
  result = runCodeGen(c, jit.gen, outBody): genProc(jit.gen, s, outBody)

  if unlikely(result.isErr):
    rewind(jit.discovery)
    return

  updateEnvironment(c, jit.discovery)

func isAvailable*(c: TCtx, prc: PSym): bool =
  ## Returns whether the bytecode for `prc` is already available.
  prc.id in c.linking.symToIndexTbl and
    c.functions[c.linking.symToIndexTbl[prc.id].int].start >= 0

proc registerProcedure*(jit: var JitState, c: var TCtx, prc: PSym): FunctionIndex =
  ## If it hasn't been already, adds `prc` to the set of procedures the JIT
  ## code-generator knowns about and sets up a function-table entry. `jit` is
  ## required to not be in the process of generating code.
  assert jit.discovery.procedures.isProcessed, "code generation in progress?"
  var index = -1

  register(jit.discovery, prc)
  # if one was added, commit to the new entry now and create a function-table
  # entry it
  c.functions.setLen(jit.discovery.procedures.len)
  for i, it in visit(jit.discovery.procedures):
    assert it == prc
    c.linking.symToIndexTbl[it.id] = LinkIndex(i)
    c.functions[i] = initProcEntry(c, it)
    index = i

  if index == -1:
    # no entry was added -> one must exist already
    result = FunctionIndex(c.linking.symToIndexTbl[prc.id])
  else:
    result = FunctionIndex(index)

proc compile*(jit: var JitState, c: var TCtx, fnc: FunctionIndex): VmGenResult =
  ## Generates code for the the given function and updates the execution
  ## environment. In addition, the function's table entry is updated with the
  ## bytecode position and execution requirements (i.e. register count). Make
  ## sure to only use `compile` when you're sure the function wasn't generated
  ## yet
  let prc = c.functions[fnc.int]
  assert prc.start == -1, "proc already generated: " & $prc.start

  result = genProc(jit, c, prc.sym)
  if unlikely(result.isErr):
    return

  fillProcEntry(c.functions[fnc.int], result.unsafeGet)

proc loadProc*(jit: var JitState, c: var TCtx, sym: PSym): VmGenResult =
  ## The main entry point into the JIT code-generator. Retrieves the
  ## information required for executing `sym`. A function table entry is
  ## created first if it doesn't exist yet, and the procedure is also
  ## generated via `compile` if it wasn't already
  let
    idx = jit.registerProcedure(c, sym)
    prc = c.functions[idx.int]

  if prc.start >= 0:
    VmGenResult.ok: (start: prc.start, regCount: prc.regCount.int)
  else:
    compile(jit, c, idx)

proc registerCallback*(c: var TCtx; pattern: string; callback: VmCallback) =
  ## Registers the `callback` with `c`. After the ``registerCallback`` call,
  ## when a procedures of which the fully qualified identifier matches
  ## `pattern` is added to the VM's function table, all invocations of the
  ## procedure at run-time will invoke the callback instead.
  # XXX: consider renaming this procedure to ``registerOverride``
  c.callbacks.add(callback) # some consumers rely on preserving registration order
  c.linking.callbackKeys.add(IdentPattern(pattern))
  assert c.callbacks.len == c.linking.callbackKeys.len
