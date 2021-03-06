module Hat.Maybe
  (gisJust,aisJust,hisJust,gisNothing,gfromJust,afromJust,hfromJust,gfromMaybe
    ,afromMaybe,hfromMaybe,glistToMaybe,alistToMaybe,hlistToMaybe,gmaybeToList
    ,amaybeToList,hmaybeToList,gcatMaybes,acatMaybes,hcatMaybes,gmapMaybe
    ,amapMaybe,hmapMaybe,Maybe(Nothing,Just),aNothing,aJust,gmaybe,amaybe
    ,hmaybe) where

import qualified Hat.PreludeBasic 
import qualified Prelude 
import Hat.Hack 
import qualified Hat.Hat as T 
import Hat.Hat  (WrapVal(wrapVal))
import Hat.Prelude 

gisJust :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun (Maybe a) Bool)

hisJust :: (T.R (Maybe a)) -> T.RefExp -> T.R Bool

gisJust pisJust p = T.ufun1 aisJust pisJust p hisJust

hisJust (T.R (Just fa) _) p = T.con0 T.mkNoSrcPos p True aTrue
hisJust (T.R Nothing _) p = T.con0 T.mkNoSrcPos p False aFalse
hisJust _ p = T.fatal p

gisNothing :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun (Maybe a) Bool)

sisNothing :: T.R (T.Fun (Maybe a) Bool)

gisNothing pisNothing p = T.uconstUse pisNothing p sisNothing

sisNothing =
  T.uconstDef T.mkRoot aisNothing
    (\ p ->
      T.uap2 T.mkNoSrcPos p (T.mkNoSrcPos !. p) (gnot T.mkNoSrcPos p)
        (gisJust T.mkNoSrcPos p))

gfromJust :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun (Maybe a) a)

hfromJust :: (T.R (Maybe a)) -> T.RefExp -> T.R a

gfromJust pfromJust p = T.ufun1 afromJust pfromJust p hfromJust

hfromJust (T.R (Just fa) _) p = T.projection T.mkNoSrcPos p fa
hfromJust (T.R Nothing _) p =
  T.uwrapForward p
    (herror (T.fromLitString T.mkNoSrcPos p "Maybe.fromJust: Nothing") p)
hfromJust _ p = T.fatal p

gfromMaybe :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun a (T.Fun (Maybe a) a))

hfromMaybe :: (T.R a) -> (T.R (Maybe a)) -> T.RefExp -> T.R a

gfromMaybe pfromMaybe p = T.ufun2 afromMaybe pfromMaybe p hfromMaybe

hfromMaybe fd (T.R Nothing _) p = T.projection T.mkNoSrcPos p fd
hfromMaybe fd (T.R (Just fa) _) p = T.projection T.mkNoSrcPos p fa
hfromMaybe _ _ p = T.fatal p

gmaybeToList :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun (Maybe a) (T.List a))

hmaybeToList :: (T.R (Maybe a)) -> T.RefExp -> T.R (T.List a)

gmaybeToList pmaybeToList p = T.ufun1 amaybeToList pmaybeToList p hmaybeToList

hmaybeToList (T.R Nothing _) p = T.con0 T.mkNoSrcPos p T.List T.aList
hmaybeToList (T.R (Just fa) _) p = T.fromExpList T.mkNoSrcPos p [fa]
hmaybeToList _ p = T.fatal p

glistToMaybe :: T.RefSrcPos -> T.RefExp -> T.R (T.Fun (T.List a) (Maybe a))

hlistToMaybe :: (T.R (T.List a)) -> T.RefExp -> T.R (Maybe a)

glistToMaybe plistToMaybe p = T.ufun1 alistToMaybe plistToMaybe p hlistToMaybe

hlistToMaybe (T.R T.List _) p = T.con0 T.mkNoSrcPos p Nothing aNothing
hlistToMaybe (T.R (T.Cons fa _) _) p = T.con1 T.mkNoSrcPos p Just aJust fa
hlistToMaybe _ p = T.fatal p

gcatMaybes ::
  T.RefSrcPos -> T.RefExp -> T.R (T.Fun (T.List (Maybe a)) (T.List a))

hcatMaybes :: (T.R (T.List (Maybe a))) -> T.RefExp -> T.R (T.List a)

gcatMaybes pcatMaybes p = T.ufun1 acatMaybes pcatMaybes p hcatMaybes

hcatMaybes fms p =
  T.uap1 T.mkNoSrcPos p
    (T.uap2 T.mkNoSrcPos p (Hat.Prelude.g_foldr T.mkNoSrcPos p)
      (T.ufun2 T.mkLambda T.mkNoSrcPos p
        (\ f_x f_y p ->
          T.uccase T.mkNoSrcPos p
            (let
              v0v0v0v0v1 (T.R (Just fm) _) p =
                T.uap1 T.mkNoSrcPos p
                  (T.pa1 T.Cons T.cn1 T.mkNoSrcPos p T.aCons fm) f_y
              v0v0v0v0v1 _ p = T.projection T.mkNoSrcPos p f_y in (v0v0v0v0v1))
            f_x)) fms) (T.fromExpList T.mkNoSrcPos p [])

gmapMaybe ::
  T.RefSrcPos ->
    T.RefExp -> T.R (T.Fun (T.Fun a (Maybe b)) (T.Fun (T.List a) (T.List b)))

hmapMaybe ::
  (T.R (T.Fun a (Maybe b))) -> T.RefExp -> T.R (T.Fun (T.List a) (T.List b))

gmapMaybe pmapMaybe p = T.ufun1 amapMaybe pmapMaybe p hmapMaybe

hmapMaybe ff p =
  T.uap2 T.mkNoSrcPos p (T.mkNoSrcPos !. p) (gcatMaybes T.mkNoSrcPos p)
    (T.uap1 T.mkNoSrcPos p (gmap T.mkNoSrcPos p) ff)

tMaybe = T.mkModule "Maybe" "Maybe.hs" Prelude.False

aisJust = T.mkVariable tMaybe 120001 130031 3 1 "isJust" Prelude.False

aisNothing = T.mkVariable tMaybe 160001 160032 3 0 "isNothing" Prelude.False

afromJust = T.mkVariable tMaybe 190001 200057 3 1 "fromJust" Prelude.False

afromMaybe = T.mkVariable tMaybe 230001 240027 3 2 "fromMaybe" Prelude.False

amaybeToList = T.mkVariable tMaybe 270001 280029 3 1 "maybeToList" Prelude.False

alistToMaybe = T.mkVariable tMaybe 310001 320032 3 1 "listToMaybe" Prelude.False

acatMaybes = T.mkVariable tMaybe 350001 350009 3 1 "catMaybes" Prelude.False

amapMaybe = T.mkVariable tMaybe 380001 380043 3 1 "mapMaybe" Prelude.False
