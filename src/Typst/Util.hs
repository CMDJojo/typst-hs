{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
module Typst.Util (
      TypeSpec(..)
    , makeElement
    , makeElementWithScope
    , makeFunction
    , makeFunctionWithScope
    , makeSymbolMap
    , argsToFields
    , nthArg
    , namedArg
    , allArgs
    , getField
    , chunks
  )
where
import Control.Monad.Reader (ReaderT(runReaderT), asks)
import Control.Monad (foldM, MonadPlus)
import Typst.Types
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import Data.List (foldl')
import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Map.Ordered as OM
import qualified Data.Vector as V
import Text.Parsec (getPosition)
import Data.Maybe (fromMaybe)

data TypeSpec =
  One ValType | Many ValType
  deriving (Show, Eq)

insertOM :: Ord k => k -> v -> OM.OMap k v -> OM.OMap k v
insertOM k v m = m OM.|> (k,v)

-- | Create element function with names for positional parameters.
makeElement :: Maybe Identifier -> Identifier -> [(Identifier, TypeSpec)] -> (Identifier, Val)
makeElement mbNamespace name specs =
  makeElementWithScope mbNamespace name specs mempty

-- | Create element function with names for positional parameters.
makeElementWithScope :: Maybe Identifier
                     -> Identifier
                     -> [(Identifier, TypeSpec)]
                     -> M.Map Identifier Val
                     -> (Identifier, Val)
makeElementWithScope mbNamespace name specs scope =
  (name, VFunction (Just qname) scope
    $ Function $ \args -> do
      pos <- getPosition
      fields <- argsToFields specs args
      pure $ VContent . Seq.singleton $ Elt qname (Just pos) fields)
 where
   qname = case mbNamespace of
             Nothing -> name
             Just ns -> ns <> "." <> name

argsToFields :: MonadFail m =>
  [(Identifier, TypeSpec)] -> Arguments -> m (M.Map Identifier Val)
argsToFields specs args' =
  OM.toMap . named <$> foldM go args' specs
 where
   hasType' TContent VContent{} = True
   hasType' TContent VString{} = True
   hasType' TContent VSymbol{} = True
   hasType' TString (VContent _) = True
   hasType' TTermItem VArray{} = True
   hasType' x y = hasType x y
   toType TContent x = VContent $ valToContent x
   toType TTermItem (VArray [VContent t, VContent d]) = VTermItem t d
   toType TTermItem (VArray [VContent t]) = VTermItem t mempty
   toType TTermItem _ = VTermItem mempty mempty
   toType TLabel (VContent [Lab t]) = VLabel t
   toType _ x = x
   go args (posname, Many ty) = do
     let (as, bs) = span (hasType' ty) (positional args)
     pure $ args{ named = insertOM posname
                          (VArray $ V.fromList $ map (toType ty) as)
                          (named args)
                , positional = bs }
   go args (posname, One ty) =
     case break (hasType' ty) (positional args) of
       ([], []) -> pure args
       (as, b:bs) ->
         pure $ args { named = insertOM posname (toType ty b) (named args)
                     , positional = as ++ bs }
       (_, [])
         -> pure args

makeFunction ::
  (forall m'. Monad m' => ReaderT Arguments (MP m') Val) -> Val
makeFunction f = VFunction Nothing mempty $ Function $ runReaderT f

makeFunctionWithScope ::
  (forall m'. Monad m' => ReaderT Arguments (MP m') Val)
  -> M.Map Identifier Val -> Val
makeFunctionWithScope f m = VFunction Nothing m $ Function $ runReaderT f

nthArg :: (Monad m, FromVal a) =>
          Int -> ReaderT Arguments (MP m) a
nthArg num = getPositional (num - 1) >>= fromVal

getPositional :: Monad m => Int -> ReaderT Arguments (MP m) Val
getPositional idx = do
  xs <- asks positional
  if idx >= length xs
     then pure VNone
     else pure $ xs !! idx

getNamed :: Monad m => Identifier -> ReaderT Arguments (MP m) (Maybe Val)
getNamed ident = do
  m <- asks named
  pure $ OM.lookup ident m

namedArg :: (Monad m, FromVal a) =>
  Identifier -> ReaderT Arguments (MP m) a
namedArg ident@(Identifier ident') = do
  mbval <- getNamed ident
  case mbval of
    Just val -> fromVal val
    Nothing -> fail $ "named argument " <> T.unpack ident' <> " not defined"

allArgs :: Monad m => ReaderT Arguments (MP m) [Val]
allArgs = asks positional

makeSymbolMap :: [(Text, Bool, Text)] -> M.Map Identifier Symbol
makeSymbolMap = foldl' go mempty
 where
   go :: M.Map Identifier Symbol -> (Text, Bool, Text) -> M.Map Identifier Symbol
   go m (name, accent, v) =
     case T.split (=='.') name of
       [] -> m
       (k:ks) ->
         M.alter (\case
                     Nothing ->
                       Just $ Symbol v accent (addVariant ks v mempty)
                     Just (Symbol dv da vs) ->
                       Just $ Symbol dv da (addVariant ks v vs))
            (Identifier k) m
   addVariant :: [Text] -> Text -> [(Set.Set Text, Text)]
              -> [(Set.Set Text, Text)]
   addVariant ks v = ((Set.fromList ks, v) :)

-- | Get field value from element, defaulting to VNone.
getField :: (MonadFail m, MonadPlus m, FromVal a) =>
            Identifier -> M.Map Identifier Val -> m a
getField name fields = fromVal $ fromMaybe VNone $ M.lookup name fields

-- | Split a list into chunks of a given size. The last chunk may be smaller.
chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks n xs = take n xs : chunks n (drop n xs)
