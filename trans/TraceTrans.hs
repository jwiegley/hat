{- ---------------------------------------------------------------------------
Transform a module for generating a trace.

Names are changed.
Module names are prefixed by 'Hat.'.
Variable names are prefixed to make room for new variable names 
refering to various traces and intermediate expressions.
Details of new name scheme near the end of this module.

No monad is used in the transformation, 
because there is nothing inherently sequential.
Instead, the definitions of the transformation functions `t*' remind of an 
attribut grammar: the arguments are the inherited attributes, the elements
of the result tuples are the synthetic attributes.
---------------------------------------------------------------------------- -}

module TraceTrans (traceTrans, Tracing(..)) where

import Language.Haskell.Exts.Annotated
import System.FilePath (takeBaseName)
import Data.Maybe (fromMaybe)
import Data.List (stripPrefix)
import Data.Set (Set)
import qualified Data.Set as Set

-- ----------------------------------------------------------------------------
-- central types

data Tracing = Traced | Trusted deriving Eq

data Scope = Global | Local deriving Eq

isLocal :: Scope -> Bool
isLocal Local = True
isLocal Global = False

type Arity = Int

-- ----------------------------------------------------------------------------
-- Transform a module

traceTrans :: 
  FilePath -> -- complete filename of the module (essential for module Main)
  Tracing -> -- whether transforming for tracing or trusting
  Environment -> -- contains already info about all imported identifiers
  Module SrcSpanInfo -> 
  Module SrcSpanInfo  -- some srcSpanInfo will be fake
traceTrans moduleFilename tracing env
  (Module span maybeModuleHead modulePragmas impDecls decls) =
  Module span (fmap (tModuleHead env declsExported maybeModuleHead) 
    (map tModulePragma modulePragmas) 
    (tImpDecls tracing impDecls)
    (declsExported ++
      [defNameMod pos modId filename traced] ++ 
      map (defNameVar Global Local modTrace) mvars ++ 
      map (defNameVar Local Local modTrace) vars ++ 
      (if traced then map (defNamePos modTrace) poss else []) 
  where
  modId = maybe "Main" getModuleId maybeModuleHead
  declsExported = decls' ++ conNameDefs ++ glabalVarNameDefs ++
                    if isMain modId 
                      then [defMain traced (traceBaseFilename moduleFilename)] 
                      else []
  conNameDefs = map (defNameCon modTrace) cons 
  globalVarNameDefs = map (defNameVar Global Global modTrace) tvars 
  modId' = nameTransModule modId
  modTrace = ExpVar pos (nameTraceInfoModule modId)
  (poss,tvars,vars,mvars,cons) = getModuleConsts consts
  (decls',consts) = tDecls Global tracing (mkRoot span) decls
traceTrans _ _ (XmlPage span _ _ _ _ _ _) = notSupported span "XmlPage"
traceTrans _ _ (XmlHybrid span _ _ _ _ _ _ _ _) = notSupported span "XmlHybrid"

-- For the complete filename of a module yields the base filename for the 
-- trace file.
-- Pre-condition: The module is a Main module
traceBaseFilename :: FilePath -> FilePath
traceBaseFilename = takeBaseName

-- obtain the module identifier
getModuleId :: ModuleHead l -> String
getModuleId (ModuleHead _ (ModuleName _ modId) _ _) = modId

tModuleHead :: ModuleHead SrcSpanInfo -> ModuleHead SrcSpanInfo
tModuleHead env decls
  (ModuleHead span moduleName maybeWarningText maybeExportSpecList) =
  ModuleHead span (nameTransModule moduleName) 
    (fmap tWarningText maybeWarningText)
    (tMaybeExportSpecList (\(ModuleName _ modId) -> modId) moduleName) 
      env maybeExportSpecList decls)

-- warnings stay unchanged
tWarningText :: WarningText l -> WarningText l
tWarningText w = w

-- not all module pragmas can be transformed
tModulePragma :: ModulePragma l -> ModulePragma l
tModulePragma (LanguagePragma l names) = LanguagePragma l names
tModulePragma (OptionsPragma l maybeTool string) = 
  OptionsPragma l maybeTool string
tModulePragma (AnnModulePragma l _) = 
  notSupported l "ANN pragma with module scope"
-- ----------------------------------------------------------------------------
-- Produce export list

tMaybeExportSpecList :: String -> -- name of this module
                        Environment ->
                        Maybe (ExportSpecList SrcSpanInfo) -> -- original list
                        [Decl SrcSpanInfo] -> -- new declarations
                        Maybe (ExportSpecList SrcSpanInfo)
tMaybeExportSpecList _ _ Nothing decls = 
  Just (ExportSpecList noSpan (concatMap makeExport decls))
tMaybeExportSpecList thisModuleId env 
  (Just (ExportSpecList span hiding exportSpecs)) decls =
  Just (ExportSpecList span (concatMap (tExportSpec env) hiding exportSpecs))
 
tExportSpec :: Environment -> ExportSpec l -> [ExportSpec l]
tExportSpec env (EVar span qname) = 
  map (EVar span) (tEntityVar env qname)
tExportSpec env (EAbs span qname) =
  EAbs span qname' : map (EVar span) qnames'
  where
  (qname', qnames') = tEntityAbs env qname
tExportSpec env (EThingAll span qname) =
  case clsTySynInfo env qname of
    Cls _ -> [EThingAll span (nameTransCls qname)]
    Ty cons fields -> 
      tExportSpec (EThingWith span qname 
                    (map conName cons ++ map fieldName fields))
  where
  conName str = ConName span (Symbol span str)
  fieldName str = VarName span (Identifier span str)
tExportSpec env (EThingWith span qname cnames) =
  EThingWith span qname' cnames' : map (EVar span) qnames'
  where
  (qname', cnames', qnames') = tEntityThingWith env qname cnames
tExportSpec env (EModuleContents span moduleName@(ModuleName _ moduleId)) =
  if thisModuleId == moduleId 
    then concatMap makeExport decls
    else [EModuleContents span (nameTransModule moduleName)]

-- Produce export entities from the declarations generated by the transformation
-- These are all entities defined in this module and meant for export.
makeExport :: Decl SrcSpanInfo -> [ExportSpec SrcPanInfo]
makeExport (TypeDecl l declHead _) = [EAbs l (getDeclHeadName declHead)]
makeExport (TypeFamDecl l declHead _) = [EAbs l (getDeclHeadName declHead)]
makeExport (DataDecl l _ _ declHead _ _) =
  [EThingAll l (getDeclHeadName declHead)]
makeExport (GDataDecl l _ _ declHead _ _ _) =
  [EThingAll l (getDeclHeadName declHead)]
makeExport (ClassDecl l _ declHead _ _) =
  [EThingAll l (getDeclHeadName declHead)]
makeExport (FunBind l match) =
  if exportedTransName name then [EVar l (Unqual l name)] else []
  where
  name = getMatchName match
makeExport (PatBind l (PVar l' name) _ _ _) =
  if exportedTransName name then [EVar l (Unqual l name)] else []
makeExport _ = []

-- Checks whether this is the name of a function that should be exported 
-- by the module.
exportedTransName :: Name l -> Bool
exportedTransName (Ident _ name) = head name `elem` ['g','a','h']
exportedTransName (Symbol _ name) = head name `elem` ['!','+','*']

getMatchName :: Match l -> Name l
getMatchName (Match _ name _ _ _) = name
getMatchName (InfixMatch _ _ name _ _ _) = name

getDeclHeadName :: DeclHead l -> Name l
getDeclHeadName (DHead _ name _) = name
getDeclHeadName (DHInfix _ _ name _) = name
getDeclHeadName (DHParen _ declHead) = getDeclHeadName declHead

-- ----------------------------------------------------------------------------
-- Produce imports

tImpDecls :: Environment -> [ImportDecl l] -> [ImportDecl l]
tImpDecls env impDecls = 
  ImportDecl {importAnn = noSpan,
              importModule = ModuleName noSpan "Prelude",
              importQualified = True,
              importSrc = False,
              importPkg = Nothing,
              importAs = Nothing,
              importSpecs = Nothing}
    -- Avoid default import of Prelude by importing it qualified.
    -- Transformed program still uses a few (qualified) Prelude
    -- functions and data constructors.
  : ImportDecl {importAnn = noSpan,
                importModule = ModuleName noSpan "Hat.Hack",
                importQualified = False,
                importSrc = False,
                importPkg = Nothing,
                importAs = Nothing,
                importSpecs = Nothing}
    -- For list syntax : and [].
    -- Is that really needed?
  : ImportDecl {importAnn = noSpan,
                importModule = ModuleName noSpan "Hat.Hat",
                importQualified = True,
                importSrc = False,
                importPkg = Nothing,
                importAs = Just (ModuleName noSpan "T",
                importSpecs = Nothing}
  -- All types and combinators for tracing, inserted by the transformation
  : map (tImportDecl env) impDecls

tImportDecl :: Environment -> ImportDecl l -> ImportDecl l
tImportDecl env importDecl = 
  if isJust (importSrc importDecl) 
    then unsupported (importAnn importDecl) "{-# SOURCE #-}"
  else if isJust (importPkg importDecl)
    then unsupported (importAnn importDecl) "explicit package name"
  else 
    importDecl{importModule = nameTransModule (importModule importDecl),
               importAs = fmap nameTransModule (importAs importDecl),
               importSpecs = fmap (tImportSpecList env) (importSpecs importDecl)
              }

tImportSpecList :: Environment -> ImportSpecList l -> ImportSpecList l
tImportSpecList env (ImportSpecList l hiding importSpecs) =
  ImportSpecList l hiding (concatMap (tImportSpec env) importSpecs)
      
-- Nearly identical with tExportSpec except for the types.  
tImportSpec :: Environment -> ImportSpec l -> [ImportSpec l]     
tImportSpec env (IVar span qname) = 
  map (IVar span) (tEntityVar env qname)
tImportSpec env (IAbs span qname) =
  IAbs span qname' : map (IVar span) qnames'
  where
  (qname', qnames') = tEntityAbs env qname
tImportSpec env (IThingAll span qname) =
  case clsTySynInfo env qname of
    Cls _ -> [IThingAll span (nameTransCls qname)]
    Ty cons fields -> 
      tExportSpec (IThingWith span qname 
                    (map conName cons ++ map fieldName fields))
  where
  conName str = ConName span (Symbol span str)
  fieldName str = VarName span (Identifier span str)
tImportSpec env (IThingWith span qname cnames) =
  IThingWith span qname' cnames' : map (IVar span) qnames'
  where
  (qname', cnames', qnames') = tEntityThingWith env qname cnames
tImportSpec env (IModuleContents span moduleName) =
  [IModuleContents span (nameTransModule moduleName)]

-- ----------------------------------------------------------------------------
-- Produce entities in either import or export list

tEntityVar :: Environment -> QName l -> [QName l]
tEntityVar env qname = 
  qNameLetVar qname : 
  case arity env qname of
    Just a | a > 0 -> [nameTraceInfoGlobalVar qname, nameWorker qname, 
                      nameShare qname]            
    Just (-1)      -> [nameShare qname]
    _              -> []

-- a class or datatype ex-/imported abstractly, or a type synonym
tEntityAbs :: Environment -> QName l -> [QName l]
tEntityAbs env qname =
  case clsTySynInfo env qname of
    Cls _ -> [nameTransCls qname]
    Ty _ _ -> [nameTransTy qname]
    Syn helpNo -> nameTransSyn qname : 
                    map (nameTransSynHelper qname) [1..helpNo]

-- a class with some methods or a datatype with some constructors/fields
tEntityThingWith :: Environment -> QName l -> [CName l] -> 
                    (QName l, [CName l], [QName l])
tEntityThingWith env qname cnames =
  case clsTySynInfo env qname of
    Cls _ -> (nameTransCls qname, 
             map nameTransLetVar cnames ++ map nameShare cnames,
             [])
    Ty _ _ -> (nameTransTy qname,
              map nameTransCon consNames ++ map nameTransField fieldNames,
              map nameTransLetVar fieldNames ++
              map nameWorker fieldNames ++
              map nameTraceInfoGlobalVar fieldNames ++
              map nameTraceInfoCon consNames)     
  where
  (consNames, fieldNames) = partition isSymbol cnames

-- ----------------------------------------------------------------------------
-- New top-level definitions for generating shared trace info
-- 
-- Trace info for positions and identifier information. They have to be 
-- top-level, so that they (and their side-effect) are only evaluated once.
-- INCOMPLETE: an optimising compiler may need noinline pragma. 
-- The variables referring to variable information need to include the 
-- position in the name, because the same variable name may be used several 
-- times.

defNameMod :: ModuleName -> String -> Bool -> Decl l
defNameMod modName@(ModuleName l modId) filename traced =
  PatBind l (PVar l (nameTraceInfoModule modName)) Nothing
    (UnGuardedRhs l
      (appN l
        [Var l nameMkModule
        ,litString l modId
        ,litString l filename
        ,Con l (if traced then qNamePreludeTrue l else qNamePreludeFalse l)]))
    Nothing

defNameCon :: Environment -> 
              Exp SrcSpanInfo -> 
              (Name SrcSpanInfo, [Name SrcSpanInfo]) -> 
              Decl SrcSpanInfo
defNameCon env moduleTrace (conName, fieldNames) =
  PatBind l (PVar l (nameTraceInfoCon conName)) Nothing
    (UnGuardedRhs l
      (appN l
        (Var l (qNameHatMkAtomConstructor l withLabels) :
         moduleTrace :
         encodeSpan l ++
         litInt l (fixPriority env conName) :
         litInt l (fromJust (arity env conName)) :
         litString l ident) :
         if withFields
           then (:[]) . mkList l .
                  map (Var l . UnQual l . nameTraceInfoVar l Global) $ 
                  fieldNames
           else []
       )))
    Nothing
  where
  l = ann conName
  ident = getId conName
  withFields = not (null fieldNames)

defNameVar :: Scope -> Scope -> Exp SrcSpanInfo -> Name SrcSpanInfo -> 
              Decl SrcSpanInfo
defNameVar defScope visScope moduleTrace varName =
  PatBind l (PVar l (nameTraceInfoVar visScope varName)) Nothing
    (UnGuardedRhs l
      (appN l
        (Var l (qNameHatMkAtomVariable l)) :
         moduleTrace :
         encodeSpan l ++
         [litInt l (fixPriority env varName),
           -- all identifiers in definition position are assumed to 
           -- be equipped with an arity; 
           -- only those defined by pattern bindings do not; they have arity 0.
          litInt l (maybe 0 (arity env varName)),
          litString l (getId varName),
          Con l (if isLocal defScope then qNamePreludeTrue l 
                                     else qNamePreludeFalse l)])) 
    Nothing
  where
  l = ann varName

defNameSpan :: Exp SrcSpanInfo -> SrcSpanInfo -> Decl SrcSpanInfo
defNameSpan moduleTrace span =
  PatBind l (PVar l (nameTraceInfoSpan span)) Nothing
    (UnGuardedRhs l
      (appN l
        (Var l (qNameHatMkSpan l) :
         moduleTrace :
         encodeSpan span)))
    Nothing
  where
  l = span

-- Encode a span in the trace file
encodeSpan :: SrcSpanInfo -> [Exp SrcSpanInfo]
encodeSpan SrcSpanInfo{srcInfoSpan=
             SrcSpan{srcSpanStartLine=beginRow
                    ,srcSpanStartColumn=beginCol
                    ,srcSpanEndLine=endRow
                    ,srcSpanEndColumn=endCol}} =
  [litInt (10000*beginRow + beginCol)
  ,litInt (10000*endRow + endCol)]
-- ----------------------------------------------------------------------------
-- Abstract data type for keeping track of constants introduced by the
-- transformation.
-- Implements sets of spans, defined this-level and local variables, 
-- defined methods and defined constructors (no duplicates)
-- this-level means defined on the currently considered declaration level,
-- local means defined in some declaration local to the current declaration.
-- Variables and constructors come with the span at which they are defined.
-- Pre-condition: a constructor is only added once.
-- A variable with span may be added several times, because
-- the span may be zero. (really?) 
-- Because same span may be used for a variable, an application etc,
-- a position may be added several times. (really?)
-- Maybe could use lists instead of sets, because no duplicates occur anyway?
-- The scope states if the variable is defined globally or locally.

data ModuleConsts = 
  MC (Set SrcSpan)  -- spans used in traces
    Set (Name SrcSpanInfo)  -- this-level variable ids for traces
    Set (Name SrcSpanInfo)  -- local variable ids for use in traces
    Set (Name SrcSpanInfo)  -- ids for methods for use in trace
    [(Name SrcSpanInfo,[Name SrcSpanInfo])]  
                            -- constructor ids for use in traces
                            -- together with field labels (global)

emptyModuleConsts :: ModuleConsts
emptyModuleConsts = MC Set.empty Set.empty Set.empty Set.empty Set.empty

addSpan :: SrcSpanInfo -> ModuleConsts -> ModuleConsts
addSpan ssi (MC poss tids ids mids cons) = 
  MC (Set.insert (srcInfoSpan ssi) poss) tids ids mids cons

-- pre-condition: name is a variable
addVar :: Name SrcSpanInfo -> ModuleConsts -> ModuleConsts
addVar name (MC poss tids ids mids cons) = 
  MC (Set.insert (srcInfoSpan (ann name)) poss) 
    (Set.insert name tids) ids mids cons

-- pre-condition: name is a data constructor
addCon :: Name SrcSpanInfo -> [Name SrcSpanInfo] -> ModuleConsts -> 
          ModuleConsts
addCon name fields (MC poss tids ids mids cons) =
  MC (Set.insert (srcInfoSpan (ann name)) poss) tids ids mids 
    ((name,fields) : cons)

-- reclassify this-level variables as methods
classifyMethods :: ModuleConsts -> ModuleConsts
classifyMethods (MC poss tids ids [] cons) = MC poss [] ids tids cons

-- both from the same declaration level
merge :: ModuleConsts -> ModuleConsts -> ModuleConsts
merge (MC poss1 tids1 ids1 mids1 cons1) (MC poss2 tids2 ids2 mids2 cons2) = 
  MC (poss1 `Set.union` poss2) (tids1 `Set.union` tids2) 
    (ids1 `Set.union` ids2) (mids1 `Set.union` mids2) (cons1 ++ cons2)

-- Combine this declaration level with a local declaration level
-- The second collection is the local one.
withLocal :: ModuleConsts -> ModuleConsts -> ModuleConsts
withLocal (MC poss1 tids1 ids1 mids1 cons1) (MC poss2 tids2 ids2 [] []) =
  MC (poss1 `Set.union` poss2) tids1 
    (ids1 `Set.union` tids2 `Set.union` ids2) mids1 cons1
withLocal _ _ = 
  error "TraceTrans.withLocal: locally defined data constructors or method"

getModuleConsts :: ModuleConsts 
                -> ([SrcSpan],[Name SrcSpanInfo],[Name SrcSpanInfo]
                   ,[Name SrcSpanInfo],[(Name SrcSpanInfo,[Name SrcSpanInfo])])
getModuleConsts (MC pos tids ids mids cons) =
  (elems pos,elems tids,elems ids,elems mids,cons)

-- ----------------------------------------------------------------------------
-- Transformation of declarations, expressions etc.

-- pre-condition: The environment contains information about all
-- identifiers declared on this level and more global,
-- but not the local scopes inside.
tDecls :: Environment -> Scope -> Tracing -> Exp SrcSpanInfo -> 
          [Decl SrcSpanInfo] ->
          ([Decl SrcSpanInfo], ModuleConsts)
tDecls env scope tracing parent decls = 
  foldr combine ([], emptyModuleConsts) 
    (map (tDecl env scope traced parent) decls)
  where
  combine :: ([Decl SrcSpanInfo], ModuleConsts) -> 
             ([Decl SrcSpanInfo], ModuleConsts) -> 
             ([Decl SrcSpanInfo], ModuleConsts)
  combine (ds1, c1) (ds2, c2) = (ds1 ++ ds2, c1 `merge` c2)


tDecl :: Environment -> Scope -> Tracing -> Exp SrcSpanInfo ->
         Decl SrcSpanInfo ->
         ([Decl SrcSpanInfo], ModuleConsts)
tDecl env _ _ _ synDecl@(TypeDecl span declHead ty) =
  (map tTypeSynonym (splitSynonym span declHead ty), emptyModuleConsts)
  where
  tTypeSynonym :: Decl SrcSpanInfo -> Decl SrcSpanInfo
  tTypeSynonym (TypeDecl span declHead ty) =
    TypeDecl span (declHead) (tType ty)
tDecl _ _ _ _ (TypeFamDecl l _ _) =
  notSupported l "type family declaration"
tDecl env Global tracing _ d@(DataDecl span dataOrNew maybeContext declHead 
                               qualConDecls maybeDeriving) =
  (DataDecl span dataOrNew (fmap tContext maybeContext) 
     (declHead) (map tQualConDecl qualConDecls) Nothing :
   -- "derive" must be empty, because transformed classes cannot be derived
   instDecl : filedSelectorDecls ++ deriveDecls
  ,foldr addConInfo (fieldSelectorConsts `merge` deriveConsts) qualConDecls)
  where
  (deriveDecls, deriveConsts) = 
    tDecls env Global Trusted (mkRoot noSpan) (derive d)
  instDecl = wrapValInstDecl env tracing maybeContext declHead qualConDecls
  (fieldSelectorDecls, fieldSelectorConsts) = mkFieldSelectors qualConDecls
tDecl _ _ _ _ (GDataDecl l _ _ _ _ _ _) =
  notSupported l "generalized algebraic data type declaration"
tDecl _ _ _ _ (DataFamDecl l _ _ _) =
  notSupported l "data family declaration"
tDecl _ _ _ _ (TypeInsDecl l _ _) =
  notSupported l "type family instance declaration"
tDecl _ _ _ _ (DataInsDecl l _ _ _ _) =
  notSupported l "data family instance declaration"
tDecl _ _ _ _ (GDataInsDecl l _ _ _ _ _) =
  notSupported l "GADT family instance declaration"
tDecl env _ tracing parent  -- class without methods
  (ClassDecl l maybeContext declHead fundeps Nothing) =
  ([ClassDecl l (fmap tContext maybeContext) (declHead) 
     (map tFunDep fundeps) Nothing]
  ,emptyModuleConsts)
tDecl env _ tracing parent  -- class with methods
  (ClassDecl l maybeContext declHead fundeps (Just classDecls)) =
  (ClassDecl l (fmap tContext maybeContext) (declHead) 
    (map tFunDep fundeps) (Just classDecls') :
   auxDecls
  ,classifyMethods declsConsts)
  where
  (classDecls', auxDecls, declsConsts) = 
    tClassDecls env tracing parent classDecls
tDecl env _ tracing parent -- class instance without methods
  (InstDecl l maybeContext instHead Nothing) =
  ([InstDecl l (fmap tContext maybeContext) (tInstHead instHead) Nothing]
  ,emptyModuleConsts)
tDecl env _ tracing parent -- class instance with methods
  (InstDecl l maybeContext instHead (instDecls)) =
  ([InstDecl l (fmap tContext maybeContext) (tInstHead instHead) 
     (Just instDecls')] :
   auxDecls
  ,classifyMethods declsConsts)
  where
  (instDecls', auxDecls, declsConsts) =
    tInstDecls env tracing parent instDecls
tDecl _ _ _ _ (DeriveDecl l _ _) =
  notSupported l "standalone deriving declaration"
tDecl _ _ _ _ (InfixDecl l assoc priority ops) =
  ([InfixDecl l assoc priority (map nameTransLetVar ops)], emptyModuleConsts)
tDecl env _ _ _ (DefaultDecl l tys) =
  ([DefaultDecl l []
   ,WarnPragmaDecl l [([], "Defaulting doesn't work in traced programs. Add type annotations to resolve ambiguities.")]]
  ,emptyModuleDecls)
tDecl _ _ _ _ (SpliceDecl l _) =
  notSupported l "Template Haskell splicing declaration"
tDecl env _ _ _ (TypeSig l names ty) =

tDecl env scope tracing parent (FunBind l matches) =

tDecl env scope tracing parent (PatBind l pat maybeTy rhs maybeBinds) =

tDecl env _ _ _ (ForImp l callConv maybeSafety maybeString name ty) =
  case maybeString >>= stripPrefix "NotHat." of
    Just origName -> tForeignImp l (qName origName) name ty
    Nothing -> 
      (ForImp l callConv maybeSafety maybeString (nameForeign name) ty :
         -- type is not renamed, original given type left unchanged  
       wrapperDecls
      ,consts)
  where
  (wrapperDecls, consts) = tForeignImp l (UnQual l (nameForeign name)) name ty
tDecl _ _ _ _ (ForExp l _ _ _ _) =
  notSupported l "foreign export declaration"
tDecl _ _ _ _ (RulePragmaDecl l _) =
  notSupported l "RULES pragma"
tDecl _ _ _ _ (DeprPragmaDecl l list) = DeprPragmaDecl l list
tDecl _ _ _ _ (WarnPragmaDecl l list) = WarnPragmaDecl l list
tDecl _ _ _ _ (InlineSig l _ _ _) =
  WarnPragmaDecl l [([], "ignore INLINE pragma")]
tDecl _ _ _ _ (InlineConlikeSig l _ _) =
  WarnPragmaDecl l [([], "ignore INLINE CONLIKE pragma")]
tDecl _ _ _ _ (SpecSig l _ _) =
  WarnPragmaDecl l [([], "ignore SPECIALISE pragma")]
tDecl _ _ _ _ (SpecInlineSig l _ _ _ _) =
  WarnPragmaDecl l [([], "ignore SPECIALISE INLINE pragma")]
tDecl _ _ _ _ (InstSig l _ _) =
  WarnPragmaDecl l [([], "ignore SPECIALISE instance pragma")]
tDecl _ _ _ _ (AnnPragma l _) =
  WarnPragmaDecl l [([], "ignore ANN pragma")]





-- Process foreign import:

tForeignImp :: SrcSpanInfo -> QName SrcSpanInfo -> Name SrcSpanInfo -> 
               Type SrcSpanInfo -> 
               ([Decls SrcSpanInfo], ModuleConsts)
tForeignImp l foreignName name ty =
  if arity == 0 
    then ([TypeSig l letVarName] (tFunType ty)
          ,FunBind l [Match l letVarName [PVar l sr, PVar l parent]
            (UnGuardedRhs l (appN l 
              [combConstUse l False
              ,Var l (UnQual l sr)
              ,Var l (UnQual l parent)
              ,Var l (Unqual lshareName)]))
            Nothing]
          ,PatBind l (PVar l shareName) Nothing        
            (UnGuardedRhs l (appN l 
              [combConstDef l False
              ,mkRoot l
              ,Var l (nameTraceInfoVar l Global name) 
              ,Lambda l [PVar l parent]
                 (appN l
                   [expFrom l ty, Var l parent, Var l foreignName])]))
            Nothing
         ,addVar l name emptyModuleConsts)
    else ([TypeSig l letVarName] (tFunType ty)
          ,FunBind l [Match l letVarName [PVar l sr, PVar l parent]
            (UnGuardedRhs l (appN l 
              [combFun l False arity
              ,Var l (nameTraceInfoVar l Global name)
              ,Var l (UnQual l sr)
              ,Var l (UnQual l parent)
              ,Var l (UnQual lworkerName)]))
            Nothing]
          ,FunBind l [Match l workerName (map (PVar l) (args++[hidden]))
            (UnGuardedRhs l (appN l
              [expFrom l tyRes
              ,ExpVar l hidden
              ,appN l (Var l foreignName : zipWith to tyArgs args)]))
            Nothing]
         ,addVar l name emptyModuleConsts)
  where
  workerName = nameWorker name
  letVarName = nameTransLetVar name
  shareName = nameShare name
  args = take arity (nameArgs name)
  hidden = nameTrace2 name
  to :: Type l -> QName l -> Exp l
  to ty arg = appN l [expTo l ty, Var l hidden, Var l arg]
    where
    l = ann ty
  arity = length tyArgs
  (tyArgs, tyRes) = decomposeFunType ty
  -- pre-condition: no type synonym appearing in type
  decomposeFunType :: Type l -> ([Type l], Type l)
  decomposeFunType (TyFun _ tyL tyR) = (tyL:tyArgs, tyRes)
    where
    (tyArgs, tyRes) = decomposeFunType tyR
  decomposeFunType ty = ([], ty)


-- Process class instances:

tInstHead :: InstHead l -> InstHead l
tInstHead (IHead l qname tys) = IHead l (nameTransCls qname) (map (tType tys))
tInstHead (IHInfix l tyL qname tyR) = 
  IHInfix l (tType tyL) (nameTransCls qname) (tType tyR)
tInstHead (IHParen l instHead) = IHParen l (tInstHead instHead)

tInstDecls :: Environment -> Tracing -> Exp SrcSpanInfo ->
              [InstDecl SrcSpanInfo] ->
              ([InstDecl SrcSpanInfo], ModuleConsts)
tInstDecls env tracing parent classDecls =
  (concat instDeclss', foldr merge emptyModuleConsts declsConsts)
  where
  (instDeclss', declsConsts) = 
    unzip (map (tInstDecl env tracing parent) instDecls)

tInstDecl :: Environment -> Tracing -> Exp SrcSpanInfo -> 
             InstDecl SrcSpanInfo -> 
             ([InstDecl SrcSpanInfo], ModuleConsts)
tInstDecl env tracing parent (InsDecl l decl) =
  (map (InsDecl l) decls', moduleConsts) 
  where
  (decls', moduleConsts) = tClassInstDecl env tracing parent decl
tInstDecl env tracing parent (InsType l _ _) =
  notSupported l "associated type definition"
tInstDecl env tracing parent (InsData l _ _ _ _) = 
  notSupported l "associated data type implementation"
tInstDecl env tracing parent (InsGData l _ _ _ _ _) =
  notSupported l "associated data type implementation using a GADT"
         

-- Process class declarations:

-- Transform any declarations in a class declaration.
tClassDecls :: Environment -> Tracing -> Exp SrcSpanInfo -> 
               [ClassDecl SrcSpanInfo] ->
               ([ClassDecl SrcSpanInfo], ModuleConsts)
tClassDecls env tracing parent classDecls =
  (concat classDeclss', foldr merge emptyModuleConsts declsConsts)
  where
  (classDeclss', declsConsts) = 
    unzip (map (tClassDecl env tracing parent) classDecls)

tClassDecl :: Environment -> Tracing -> Exp SrcSpanInfo -> 
              ClassDecl SrcSpanInfo -> 
              ([ClassDecl SrcSpanInfo], ModuleConsts)
tClassDecl env tracing parent (ClsDecl l decl) =
  (map (ClsDecl l) decls', moduleConsts) 
  where
  (decls', moduleConsts) = tClassInstDecl env tracing parent decl
tClassDecl env tracing parent (ClsDataFam l _ _ _) = 
  notSupported l "declaration of an associated data type"
tClassDecl env tracing parent (ClsTyFam l _ _) =
  notSupported l "declaration of an associated type synonym"
tClassDecl env tracing parent (ClsTyDef l _ _) =
  notSupported l "default choice for an associated type synonym"

-- Transform a standard declaration inside a class or instance declaration.
-- Basically patch the result of the standard transformation of such a 
-- declaration.
tClassInstDecl :: Environment -> Tracing -> Exp SrcSpanInfo ->
                  Decl SrcSpanInfo ->
                  ([Decl SrcSpanInfo], ModuleConsts)
tClassInstDecl env tracing parent decl@(FunBind _ _) =
  -- Worker needs to be local, because it does not belong to the 
  -- class / instance, nor can it be outside of it.
  -- (Cannot use arity optimisation for a method anyway.)
  ([FunBind l [addToWhere match workerDecls]], moduleConsts)
  where
  (FunBind l [match] : _ : workerDecls, moduleConsts) =
    tDecl env Local tracing parent decl
tClassInstDecl env tracing parent decl@(PatBind _ _ _ _ _) =
  -- Currently don't do any patching!
  -- Use of sharing variable needs to be qualified if class name needs to be
  -- qualified (still covers not all necessary cases)
  -- note when declaring instance the class may only be imported qualified
  -- What does the above mean??
  tDecl env Local tracing parent decl
tClassInstDecl env tracing parent decl@(TypeSig l names ty) =
  -- For every method type declaration produce an additional type declaration
  -- of the sharing variable.
  ([TypeSig l (tSpanShares names) (tConstType ty), tySig'], moduleConsts)
  where
  ([tySig'], moduleConsts) = tDecl env Local tracing parent decl
  -- This should cover all declarations that can occur.


addToWhere :: Match l -> [Decl l] -> Match l
addToWhere (Match l name pats rhs Nothing) decls =
  Match l name pats rhs (Just BDecls l decls)
addToWhere (Match l name pats rhs (Just (BDecls l' ds))) decls =
  Match l name pats rhs (Just (BDecls l' (ds ++ decls)))
addToWhere (InfixMatch l pl name pr rhs Nothing) decls =
  InfixMatch l pl name pr rhs (Just BDecls l decls)
addToWhere (InfixMatch l pl name pr rhs maybeBinds) decls =
  InfixMatch l pl name pr rhs (Just (BDecls l' (ds ++ decls)))

  -- Split a synonym into a core synonym plus several helpers.
  -- pre-condition: the declaration is a type synonym declaration.
  -- post-condition: all resulting declarations are type synonym declarations.
  -- The helper synonyms are necessary for the following reason:
  -- The known-arity optimisation requires that workers of functions with
  -- known arity are defined on the same level as their wrapper, not local
  -- to them. If the original function was recursive, the worker will be
  -- recursive instead of calling the wrapper (as without known-arity opt.).
  -- Hence if the original definition had a type signature, then the worker
  -- needs a type signature as well (the wrapper gets one anyway),
  -- because otherwise its inferred type might not be general enough 
  -- (polymorphic recursion) or too general (type class ambiguities,
  -- problems with existential types).
  -- Transformation of the original type signature into the worker type
  -- signature is not uniform: function types are handled specially.
  -- So if the type includes a type synonym it may not be possible to use
  -- the transformed type synonym, but the original one has to be expanded
  -- and transformed in this non-uniform way. However, in general a type
  -- synonym cannot be expanded, because the rhs might not be in scope at
  -- the synonym use site. Hence a type synonym is split into an outer part
  -- consisting of function types, type applications and type variables, 
  -- which can and may need to be expanded, and several inner type parts,
  -- for which new helper type synonyms are defined. These are always
  -- ex- and imported with the type synonym itself.
  -- A lot of effort, but it does work in the end.
splitSynonym :: Decl SrcSpanInfo -> [Decl SrcSpanInfo]
splitSynonym typeDecl@(TypeDecl span declHead ty) =
  typeDecl : zipWith mkTypeDecl (hrhss ty) [1..]
  where
  mkTypeDecl :: Type SrcSpanInfo -> Int -> Decl SrcSpanInfo
  mkTypeDecl hrhs no =
    TypeDecl span (mapDeclHead (nameTransTySynHelper no) declHead) hrhs
  hrhss ty = case ty of
    (TyParen l ty') -> hrhss ty'

  -- It is vital that this `go' agrees with the `go' in `splitSynonym' in
  -- AuxFile. Sadly the module structure of Hat is such that the two
  -- functions cannot sit next to each other (or be combined) without
  -- introducing a separate module for them.
  go :: Type SrcSpanInfo -> [Type SrcSpanInfo] -> [Type SrcSpanInfo]
  go (TyForall l _ _) tys = notSupported l "forall in type synonym"
  go (TyFun l tyL tyR) [] = tyL : go tyR
  go ty@(TyTuple _ _ _) [] = [ty]
  go ty@(TyList _ _) [] = [ty]
  go (TyApp l tyL tyR) tys = go tyL (tyR:tys)
  go (TyVar _ _) tys = []
  go (TyCon l tyCon) tys = 
    if isExpandableTypeSynonym env tyCon 
      then expandTypeSynonym env tyCon tys go  -- continuation
      else []
  go (TyParen l ty) = map (TyParen l) (go ty)
  go (TyInfix l tyL tyCon tyR) tys =
    if isExpandableTypeSynonym env tyCon
      then expandTypeSynonym env tyCon (tyL:tyR:tys) go
      else []
  go (TyKind l ty kind) tys = notSupported l "kind annotation in type syonym"

mapDeclHead :: (Name l -> Name l) -> DeclHead l -> DeclHead l
mapDeclHead f (DHead l name tyVarBinds) = DHead l (f name) tyVarBinds
mapDeclHead f (DHInfix l tyVarBindL name tyVarBindR) = 
  DHInfix l tyVarBindL (f name) tyVarBindR
mapDeclHead f (DHParen l declHead) = DHParen l (mapDeclHead f declHead)

-- Process data type declarations:

addConInfo :: QualConDecl SrcSpanInfo -> ModuleConsts -> ModuleConsts
addConInfo (QualConDecl _ Nothing Nothing condecl) =
  addConDeclModuleConsts condecl
addConInfo (QualConDecl l _ _ _) = 
  notSupported l "existential quantification with data constructor"

addConDeclModuleConsts :: ConDecl SrcSpanInfo -> ModuleConsts -> ModuleConsts
addConDeclModuleConsts (ConDecl l name bangtypes) =
  addCon name [] 
addConDeclModuleConsts (InfixConDecl l btL name btR) =
  addCon name []
addConDeclModuleConsts (RecDecl l name fieldDecls) =
  addCon name (concatMap (\(FieldDecl _ names _) -> names) fieldDecls)


-- ----------------------------------------------------------------------------
-- Error for non-supported language features

notSupported :: SrcSpanInfo -> String -> a
notSupported span construct = 
  "hat-trans: unsupported language construct \"" ++ construct ++ "\" at " ++ 
    show span


-- ----------------------------------------------------------------------------
-- New names
-- Module names and hence all qualifications are prefixed.
-- Names of classes, type constructors and type variables remain unchanged.
-- Names of data constructors remain unchanged.
-- (everything but expression variables)
-- As prefix characters only those characters can be chosen that do
-- not start a reserved identifier or operator. Otherwise the transformation
-- might create a reserved identifier.
-- (uppercase identifiers can be prefixed by such a character, because
-- a reserved identifier will never be created by prefixing)

-- names referring to traces (or parts thereof) of program fragments:

nameTraceInfoModule :: ModuleName l => Name l
nameTraceInfoModule (ModuleName l ident) = Ident l ('t' : ident)

nameTraceInfoVar :: Id i => SrcSpanInfo -> Scope -> i -> i
nameTraceInfoVar span Global = prefixName 'a' '+'
nameTraceInfoVar span Local = prefixSpanName 'a' '+' span

nameTraceInfoGlobalVar :: Id i => i -> i
nameTraceInfoGlobalVar = prefixName 'a' '+'

nameTraceInfoCon :: Id i => i -> i
nameTraceInfoCon = prefixName 'a' '+'

nameTraceInfoSpan :: SrcSpanInfo -> Name SrcSpanInfo
nameTraceInfoSpan span = Ident span ('p' : showsEncodePos span "")

-- names referring to transformed program fragments:

nameTransModule :: ModuleName l -> ModuleName l
nameTransModule (ModuleName l name) = ModuleName l 
  (fromMaybe (if name == "Main" then name else "Hat." ++ name) 
    (stripPrefix "NotHat." name)) 

-- The unqualfied names in the namespace of classes, types and type synonyms 
-- are left unchanged, but the module changes.
-- Similarly type variable names are left unchanged.

nameTransCls :: Id i => i -> i
nameTransCls = updateId id  -- unchanged

nameTransTy :: Id i => i -> i
nameTransTy = updateId id  -- unchanged

nameTransSyn :: Id i => i -> i
nameTransSyn = updateId id  -- unchanged

-- Names of helper synonyms are a bit of a hack; a name conflict is possible.
-- We just do not want to prefix all names in the namespace.
nameTransSynHelper :: Id i => i -> Int -> i
nameTransSynHelper syn no = updateToken (++ ("___" ++ show no)) syn
  where 
  update (Ident l name) = Ident l (name ++ "___" ++ show no)
  update (Symbol _ _) = 
    error "TraceTrans, nameTransSynHelper: synom name is a symbol"

nameTransTyVar :: Name l -> Name l
nameTransTyVar = id  -- unchanged

nameTransCon :: Id i => i -> i
nameTransCon = updateId id  -- unchanged

nameTransField :: Id i => i -> i
nameTransField = prefixName 'b' '^'

nameTransLetVar :: Id i => i -> i
nameTransLetVar = prefixName 'g' '!'

nameTransLambdaVar :: Id i => i -> i
nameTransLambdaVar = prefixName 'f' '&'

-- internal, local names

-- refering to partially transformed expression
nameWorker :: Id i => i -> i
nameWorker = prefixName 'h' '*'

-- refering to original (unwrapped) foreign import
nameForeign :: Id i => i -> i
nameForeign = prefixName 'f' '&'

-- names for new variables in transformed expressions:
-- variable for sharing in transformation of pattern binding
nameShare :: Id i => i -> i
nameShare = prefixName 's' '|'

-- variable for a trace including span
nameTraceShared :: Id i => SrcSpanInfo -> i -> i
nameTraceShared = prefixSpanName 'j' '$'

-- variable for parent
nameParent :: Name SrcSpanInfo
nameParent = Ident noSpan "p"

-- variable for a trace
nameTrace :: Id i => i -> i
nameTrace = prefixName 'j' '$'

-- second variable for a trace
nameTrace2 :: Id i => i -> i
nameTrace2 = prefixName 'k' '@'

-- name for a local variable for a source reference
nameSR :: Id i => i -> i
nameSR = prefixName 'p' '%'

-- intermediate function
nameFun :: Name SrcSpanInfo
nameFun = Ident noSpan "h"

-- infinite list of var ids made from one id (for function clauses)
nameFuns :: Id i => i -> [i]
nameFuns = prefixNames 'y' '>'

-- infinite list of var ids made from one id (for naming arguments)
nameArgs :: Id i => i -> [i]
nameArgs = prefixNames 'z' '^'

-- a single id made from a span (different from below)
nameFromSpan :: SrcSpanInfo -> Name SrcSpanInfo
nameFromSpan span = Ident span ('v' : showsEncodeSpan span "n")

-- infinite list of ids made from a span
namesFromSpan :: SrcSpanInfo -> [Name SrcSpanInfo]
namesFromSpan span =
  map (Ident span . ('v':) . showsEncodeSpan span . ('v':) . show) 
    [1..]

-- Generation of new variables

showsEncodeSpan :: SrcSpanInfo -> ShowS
showsEncodeSpan span = shows beginRow . ('v':) . shows beginColumn . ('v':) 
  . shows endRow  . ('v':) . shows endColumn
  where
  beginRow = srcSpanStartLine srcSpan
  beginColumn = srcSpanStartColumn srcSpan
  endRow = srcSpanEndLine srcSpan
  endColumn = srcSpanEndColumn srcSpan
  srcSpan = srcInfoSpan span

showsSymEncodeSpan :: SrcSpanInfo -> ShowS
showsSymEncodeSpan span = 
  \xs -> numToSym (show beginRow) ++ '=' : numToSym (show beginColumn) ++ '=' 
    : numToSym (show endRow) ++ '=' : numToSym (show endColumn) ++ xs 
  where
  beginRow = srcSpanStartLine srcSpan
  beginColumn = srcSpanStartColumn srcSpan
  endRow = srcSpanEndLine srcSpan
  endColumn = srcSpanEndColumn srcSpan
  srcSpan = srcInfoSpan span

prefixName :: Id i => Char -> Char -> i -> i
prefixName c d = updateId update
  where
  update (Ident l name) = Ident l (c:name)
  update (Symbol l name) = Ident l (d:name)

-- really used with that general type?
prefixModName :: Id i => Char -> i -> i
prefixModName c = updateToken update
  where
  update (Ident l name) = Ident l (c: map (\c->if c=='.' then '_' else c) name)

prefixSpanName :: Id i => Char -> Char -> SrcSpanInfo -> i -> i
prefixSpanName c d span = updateId update
  where
  update (Ident l name) = Ident l (c : showsEncodeSpan span name)
  update (Symbol l name) = Symbol l (d : showsSymEncodeSpan span name)

prefixNames :: Id i => Char -> Char -> i -> [i]
prefixNames c d name = map (($ name) . updateId . update) [1..]
  where
  update no (Ident l name) = Ident l (c : show no ++ name)
  update no (Symbol l name) = Symbol l (d : numToSym (show no) ++ name)

numToSym :: String -> String
numToSym = map (("!#$%&*+^@>" !!) . digitToInt)

-- Actual identifier modification

class Id a where
  -- apply function to unqualified name part 
  -- and prefix module name (if qualified)
  updateId :: (Name l -> Name l) -> a -> a
  -- whether a symbol (operator) or a normal identifier
  isSymbol :: a -> Bool
  getId :: a -> String

instance Id (QName SrcSpanInfo) where
  updateId f (Qual l moduleName name) = 
    Qual l (tModuleName moduleName) (updateId f name)
  updateId f (UnQual l name) = UnQual l (updateId f name)
  updateId f (Special l specialCon) =
    case specialCon of
      UnitCon l' -> newName "Tuple0"
      ListCon l' -> newName "List"
      FunCon l' -> newName "Fun"
      TupleCon l' Boxed arity -> newName ("Tuple" ++ show arity)
      TupleCon l' Unboxed _ -> notSupported l "unboxed tuple"
      Cons l' -> newName "List"
      UnboxedSingleCon l' -> 
        notSupported l "unboxed singleton tuple constructor"
    where
    newName :: String -> QName l
    newName id = Qual l tracingModuleNameShort (Ident l id) 
  isSymbol (Qual _ _ name) = isSymbol name
  isSymbol (UnQual _ name) = isSymbol name
  isSymbol (Special _ _) = True
  getId (Qual _ _ name) = getId name
  getId (UnQual _ name) = getId name

instance Id (Name l) where
  updateId f name = f name  
  isSymbol (Identifier _ _) = False
  isSymbol (Symbol _ _) = True
  getId (Identifier _ ident) = ident
  getId (Symbol _ ident) = ident

instance Id (QOp l) where
  updateId f (QVarOp l qname) = QVarOp l (updateId f qname)
  updateId f (QConOp l qname) = QConOp l (updateId f qname)
  isSymbol (QVarOp _ _) = False
  isSymbol (QConOp _ _) = True
  getId (QVarOp _ qname) = getId qname
  getId (QConOp _ qname) = getId qname

instance Id (Op l) where
  updateId f (VarOp l name) = VarOp l (updateId f name)
  updateId f (ConOp l name) = ConOp l (updateId f name)
  isSymbol (VarOp _ _) = False
  isSymbol (ConOp _ _) = True
  getId (VarOp _ name) = getId name
  getId (ConOp _ name) = getId name

instance Id (CName l) where
  updateId f (VarName l name) = VarName l (updateId f name)
  updateId f (ConName l name) = ConName l (updateId f name)
  isSymbol (VarName _ _) = False
  isSymbol (ConName _ _) = True
  getId (VarOp _ name) = getId name
  getId (ConOp _ name) = getId name

-- Hardwired identifiers

tracingModuleNameShort :: ModuleName SrcSpanInfo
tracingModuleNameShort = ModuleName noSpan "T"

mkTypeToken :: l -> String -> QName l 
mkTypeToken l id = 
  if id `elem` (map ("from"++) preIds ++ map ("to"++) preIds)
    then Qual l tracingModuleNameShort (Ident l id)
    else UnQual l (Ident l id)
  where
  -- list should include all types allowed in foreign imports
  preIds = ["Id", "IO", "Tuple0", "Tuple2", "Char", "Int", "Integer", 
            "Float", "Double"]

-- names for trace constructors

qNameHatMkModule :: l -> QName l
qNameHatMkModule l = qNameHatIdent l "mkModule"

qNameHatMkAtomConstructor :: l -> Bool -> QName l
qNameHatMkAtomConstructor l withFields =
  qNameHatIdent l 
    (if withFields then "mkConstructorWFields" else "mkConstructor")

qNameHatMkAtomVariable :: l -> QName l
qNameHatMkAtomVariable = qNameHatIdent l "mkVariable"

qNameHatMkSpan :: l -> QName l
qNameHatMkSpan l = qNameHatIdent l "mkSrcPos"

qNameHatMkNoSpan :: L -> QName l
qNameHatMkNoSpan l = qNameHatIdent l "mkNoSrcPos"

qNamePreludeTrue :: l -> QName l
qNamePreludeTrue l = qNamePreludeIdent l "True"

qNamePreludeFalse :: l -> QName l
qNamePreludeFalse l = qNamePreludeIdent l "False"

qNamePreludeIdent :: l -> String -> QName l
qNamePreludeIdent l ident = Qual l (ModuleName l "Prelude") (Ident l ident)

qNameHatIdent :: l -> String -> QName l
qNameHatIdent l ident = Qual l (ModuleName l "Hat") (Ident l ident)


-- ----------------------------------------------------------------------------
-- Wrapping of untransformed code

expTo :: l -> Type l -> Exp l
expTo = expType True

expFrom :: l -> Type l -> Exp l
expFrom = expType False

-- The following assumes a limited form of types as they
-- occur in foreign import / export declarations.
-- Variables of kind other than * pose a problem.
expType :: Bool -> l -> Type l -> Exp l
expType to l (TyForall l _ _ _) = notSupported undefined "local type forall"
expType to l (TyFun l tyL tyR) =
  appN l 
    [Var l (mkTypeToken (prefix to ++ "Fun"))
    ,expType (not to) l tyL
    ,expType to pos tyR]
expType to l (TyTuple l boxed tys) =
  appN l
    (Var l (mkTypeToken (prefix to ++ "Tuple" ++ show (length tys))) :
     map (expType to l) tys)
expType to l (TyList l ty) =
  appN l [Var l (mkTypeToken (prefix to ++ "List")), expType to l ty]
expType to l (TyApp l tyL tyR) = 
  App l (expType to l tyL) (expType to l tyR)
expType to l (TyVar l _) =
  Var l (mkTypeToken (prefix to ++ "Id"))
expType to l (TyCon l qName) = 
  Var l (mkTypeToken (prefix to ++ getId qName))

prefix :: Bool -> String
prefix True = "to"
prefix False = "from"
  

-- ----------------------------------------------------------------------------
-- Useful stuff

-- Build parts of syntax tree:

-- Build n-ary application
-- pre-condition: list is non-empty
appN :: l -> [Exp l] -> Exp l
appN _ [e] = e
appN l (e:es) = App l e (appN l es)

litInt :: Integral i => l -> i -> Lit l
litInt l i = Lit l (Int l (fromIntegral i) (show i))

litString :: l -> String -> Lit l
litString l str = Lit l (Str l str str) 
  

-- bogus span, does not appear in the source
noSpan :: SrcSpanInfo
noSpan = noInfoSpan (SrcSpan "" 0 0 0 0)