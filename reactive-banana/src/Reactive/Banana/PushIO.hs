{-----------------------------------------------------------------------------
    Reactive Banana
    
    A push-driven implementation
------------------------------------------------------------------------------}
{-# LANGUAGE TypeFamilies, FlexibleInstances, EmptyDataDecls, GADTs,
     TupleSections, BangPatterns #-}
module Reactive.Banana.PushIO where

import Reactive.Banana.Model hiding (Event, Behavior, interpret)
import qualified Reactive.Banana.Model as Model

import Data.Vault (Vault)
import qualified Data.Vault as Vault


import Control.Applicative
import Control.Arrow (second)
import Control.Monad
import Control.Monad.IO.Class       (liftIO)
import Control.Monad.Trans.Class    (lift)
import Control.Monad.Trans.Identity
import Control.Monad.Trans.State
import Control.Monad.Trans.Writer
import Data.Maybe
import Data.Monoid
import System.IO.Unsafe

import System.IO
-- debug s = hPutStrLn stderr s

{-----------------------------------------------------------------------------
    Observable sharing
    
    References can be used in the  Store  monad.
    This mimicks the case where unique IDs are used
    to look up a value in the environment.
    In this case, the environment is passed around by the  Store  monad.
------------------------------------------------------------------------------}
-- store monad
type Store = StateT Vault IO
-- references to observe sharing
type Ref a = Vault.Key a

runStore :: Store a -> IO a
runStore m = evalStateT m Vault.empty

-- create a new reference.
newRef   :: IO (Ref a)
-- read a reference. Only possible in the  Store  monad.
readRef  :: Ref a -> Store (Maybe a)
writeRef :: Ref a -> a -> Store ()

newRef         = Vault.newKey
readRef ref    = Vault.lookup ref <$> get
writeRef ref x = modify $ Vault.insert ref x

-- invalid reference that may not store values
invalidRef = error "Store: invalidRef. This is an internal bug."

{-----------------------------------------------------------------------------
    Cache, generalities
------------------------------------------------------------------------------}
-- A cache stores values of different types
-- and finalizers to change them.
data Cache = Cache {
              vault :: Vault
            , initializers :: [VaultChanger]
            , finalizers   :: [VaultChanger] }
type VaultChanger = Run ()

emptyCache :: Cache
emptyCache = Cache Vault.empty [] []

-- monad to build the network in
type Compile = StateT Cache Store
-- monad to run the network in
type Run     = StateT Vault IO

runCompile :: Compile a -> Store (a, Cache)
runCompile m = runStateT m $ Cache { vault = Vault.empty, initializers = [], finalizers = [] }

registerInitializer, registerFinalizer :: VaultChanger -> Compile ()
registerFinalizer m   = modify $
    \cache -> cache { finalizers   = finalizers cache ++ [m] }
registerInitializer m = modify $
    \cache -> cache { initializers = initializers cache ++ [m] }

runRun :: Run a -> Cache -> IO (a, Cache)
runRun m cache = do
        let vault1 = vault cache
        -- run the initializers
        vault2     <- runVaultChangers (initializers cache) vault1
        -- run the action
        (x,vault3) <- runStateT m vault2
        -- run all the finalizers              
        vault4     <- runVaultChangers (finalizers cache) vault3
        -- return new cache
        return (x,cache{ vault = vault4 })
    where
    runVaultChangers = execStateT . sequence_

-- helper functions for reading and writing keys into the vault cache
writeVaultKey ref x = do
    vault  <- get
    let vault' = Vault.insert ref x vault
    put $ vault'
readVaultKey ref = Vault.lookup ref <$> get

{-----------------------------------------------------------------------------
    Cache, particular reference types
------------------------------------------------------------------------------}
-- CacheRef
-- A simple value to be cached. Lasts one phase. Useful for sharing.
type CacheRef a = Vault.Key a

newCacheRef   :: Compile (CacheRef a)
readCacheRef  :: CacheRef a -> Run (Maybe a)
writeCacheRef :: CacheRef a -> a -> Run ()

newCacheRef      = do
    key <- liftIO $ Vault.newKey
    registerFinalizer $ put . Vault.delete key =<< get
    return key
readCacheRef  = readVaultKey
writeCacheRef = writeVaultKey

-- Accumulation values.
-- Cache and accumulate a value over several phases.
type AccumRef a = Vault.Key a

newAccumRef    :: a -> Compile (AccumRef a)
readAccumRef   :: AccumRef a -> Run a
updateAccumRef :: AccumRef a -> (a -> a) -> Run a -- strict!

newAccumRef x     = do
    ref    <- liftIO $ Vault.newKey
    vault2 <- Vault.insert ref x . vault <$> get
    modify $ \cache -> cache { vault = vault2 }
    return ref
readAccumRef ref  =
    fromJustError "Reactive.Banana.PushIO.readAccumRef: internal error"
    <$> readVaultKey ref
updateAccumRef ref f = do
    Just x <- readVaultKey ref 
    let !y = f x
    writeVaultKey ref y
    return y

fromJustError e = maybe (error e) id

-- BehaviorRef.
-- Cache and accumulate a value over several phases,
-- but updates are only visible at the beginning of a new phase.
-- (accumulator, temporary reference for each phase)
type BehaviorRef a = (AccumRef a, CacheRef a)

newBehaviorRefPoll   :: IO a -> Compile (BehaviorRef a)
newBehaviorRefAccum  :: a -> Compile (BehaviorRef a)
readBehaviorRef      :: BehaviorRef a -> Run a
updateBehaviorRef    :: BehaviorRef a -> (a -> a) -> Run () -- strict!

newBehaviorRef m = do
    temp <- newCacheRef
    registerInitializer $ writeCacheRef temp =<< m
    return (undefined, temp)
newBehaviorRefPoll    = newBehaviorRef . liftIO
newBehaviorRefAccum x = do
    acc  <- newAccumRef x
    (_,temp) <- newBehaviorRef $ readAccumRef acc
    return (acc, temp)
readBehaviorRef   (_, temp)   =
    fromJustError "Reactive.Banana.PushIO.readBehaviorRef: internal error"
    <$> readCacheRef temp
updateBehaviorRef (acc, temp) = void . updateAccumRef acc


{-----------------------------------------------------------------------------
    Abstract syntax tree
------------------------------------------------------------------------------}
data Accum
data Shared
data Linear

type EventStore a = [(Channel, CacheRef a)]

type family   Event t a
type instance Event Accum  a = (Ref (EventStore a), EventD Accum a)
type instance Event Shared a = (Ref (EventStore a), EventD Shared a)
type instance Event Linear a = EventD Linear a

data EventD t :: * -> * where
    Filter    :: (a -> Bool) -> Event t a -> EventD t a
    ApplyE    :: Behavior t (a -> b) -> Event t a -> EventD t b
    AccumE    :: a -> Event t (a -> a) -> EventD t a
    Union     :: Event t a -> Event t a -> EventD t a
    Never     :: EventD t a
    
    -- internal combinators
    Input         :: Channel -> Key a -> EventD t a
    Reactimate    :: Event t (IO ()) -> EventD t ()
    
    ReadCache     :: Channel -> CacheRef a -> EventD t a
    WriteCache    :: CacheRef a -> Event t a -> EventD t a
    
    UpdateAccum    :: AccumRef a    -> Event t (a -> a) -> EventD t a
    UpdateBehavior :: BehaviorRef a -> Event t (a -> a) -> EventD t ()


type BehaviorStore a = BehaviorRef a

type family   Behavior t a
type instance Behavior Accum  a = (Ref (BehaviorStore a), BehaviorD Accum  a)
type instance Behavior Shared a = (Ref (BehaviorStore a), BehaviorD Linear a)
type instance Behavior Linear a = (Ref (BehaviorStore a), BehaviorD Linear a)

data BehaviorD t a where
    Pure         :: a -> BehaviorD t a
    ApplyB       :: Behavior t (a -> b) -> Behavior t a -> BehaviorD t b
    AccumB       :: a -> Event t (a -> a) -> BehaviorD t a
    Poll         :: IO a -> BehaviorD t a
    
    -- internal combinators
    ReadBehavior :: BehaviorRef a -> BehaviorD t a

{-----------------------------------------------------------------------------
    Storing heterogenous input values
------------------------------------------------------------------------------}
type Channel  = Integer     -- identifies an input
type Key      = Vault.Key 
type Universe = Vault.Vault

newUniverseKey :: IO (Key a)
newUniverseKey = Vault.newKey

fromUniverse :: Key a -> Universe -> Maybe a
fromUniverse = Vault.lookup

toUniverse :: Key a -> a -> Universe
toUniverse k a = Vault.insert k a Vault.empty

{-----------------------------------------------------------------------------
    Compilation
------------------------------------------------------------------------------}
-- allocated caches for acummulated and external behaviors,
-- turn them into reads from the cache
type CompileReadBehavior = WriterT [Event Shared ()] Compile

compileReadBehavior :: Event Accum () -> Compile (Event Shared ())
compileReadBehavior e1 = do
        (e,es) <- runWriterT (goE e1)
        -- include updates to Behavior as additional events
        let union e1 e2 = (invalidRef, Union e1 e2)
        return $ foldr1 union (e:es)
    where    
    -- boilerplate traversal for events
    goE :: Event Accum a -> CompileReadBehavior (Event Shared a)
    goE (ref, Filter p e )      = (ref,) <$> (Filter p   <$> goE e)
    goE (ref, Union e1 e2)      = (ref,) <$> (Union      <$> goE e1 <*> goE e2)
    goE (ref, ApplyE b e )      = (ref,) <$> (ApplyE     <$> goB b  <*> goE e )
    goE (ref, AccumE x e )      = (ref,) <$> (AccumE x   <$> goE e)
    goE (ref, Reactimate e)     = (ref,) <$> (Reactimate <$> goE e)
    goE (ref, Never)            = (ref,) <$> (pure Never)
    goE (ref, Input c k)        = (ref,) <$> (pure $ Input c k)

    -- almost boilerplate traversal for behaviors
    goB :: Behavior Accum a -> CompileReadBehavior (Behavior Shared a)
    goB (ref, Pure x      ) = (ref,) <$> (Pure   <$> return x)
    goB (ref, ApplyB bf bx) = (ref,) <$> (ApplyB <$> goB bf <*> goB bx)
    goB (ref, Poll io     ) = (ref,) <$> (ReadBehavior <$> makeRef)
        where
        makeRef = do
            m <- lift . lift $ readRef ref
            case m of
                Just r  -> return r
                Nothing -> do
                    r <- lift $ newBehaviorRefPoll io
                    lift . lift $ writeRef ref r
                    return r
    goB (ref, AccumB x e  ) = (ref,) <$> (ReadBehavior <$> makeRef)
        where
        makeRef = do
            m <- lift . lift $ readRef ref
            case m of
                Just r  -> return r
                Nothing -> do
                    -- create new BehaviorRef and share it
                    r <- lift $ newBehaviorRefAccum x
                    lift . lift $ writeRef ref r

                    -- remove  accumB  from the other events
                    e <- goE e
                    tell [(invalidRef, UpdateBehavior r e)]
                    return r

-- fan out unions into linear paths
type EventLinear a = (Channel, Event Linear a)

compileUnion :: Event Shared a -> Compile [Event Linear a]
compileUnion e = map snd <$> goE e
    where
    goE :: Event Shared a -> Compile [EventLinear a]
    goE (ref, Filter p e )        = cacheEvents ref (map2 (Filter p) <$> goE e)
    goE (ref, ApplyE b e )        = cacheEvents ref (map2 (ApplyE b) <$> goE e)
    goE (ref, AccumE x e )        = cacheEvents ref (compileAccumE x =<< goE e)
    goE (_  , UpdateBehavior b e) = map2 (UpdateBehavior b) <$> goE e
    goE (_  , Reactimate e)       = map2 (Reactimate)      <$> goE e
    goE (_  , Union e1 e2)        = (++) <$> goE e1 <*> goE e2
    goE (_  , Never      )        = return []
    goE (_  , Input channel key)  = return [(channel, Input channel key)]
    
    compileAccumE :: a -> [EventLinear (a -> a)] -> Compile [EventLinear a]
    compileAccumE x es = do
        ref <- newAccumRef x
        return $ map2 (UpdateAccum ref) es
    
    cacheEvents :: Ref (EventStore a)
                -> Compile [EventLinear a] -> Compile [EventLinear a]
    cacheEvents ref mes = do
        m <- lift $ readRef ref
        case m of
            Just cached -> do
                return $ map (\(c,r) -> (c, ReadCache c r)) cached
            Nothing     -> do
                -- compile input events
                es     <- mes
                -- allocate corresponding cache references and share them
                cached <- forM es $ \(c,_) -> do r <- newCacheRef; return (c,r)
                lift $ writeRef ref cached
                -- return events that also write to the cache
                return $ zipWith (second . (WriteCache . snd)) cached es

map2 = map . second

-- compile a behavior
-- FIXME: take care of sharing, caching
compileBehaviorEvaluation :: Behavior Linear a -> Run a
compileBehaviorEvaluation = goB
    where
    goB :: Behavior Linear a -> Run a
    goB (ref, Pure x)            = return x
    goB (ref, ApplyB bf bx)      = goB bf <*> goB bx
    goB (ref, ReadBehavior refb) = readBehaviorRef refb


-- compile path into an IO action
type Path = (Channel, Universe -> Run (IO ()))
-- (input_channel, \input_value ->
--      do change event_graph_state; return (reactimates_to_be_run) )

compilePath :: Event Linear () -> Path
compilePath e = goE e (const $ return nop)
    where
    goE :: Event Linear a -> (a -> Run (IO ())) -> Path
    goE (Filter p e)         k = goE e $ \x -> if p x then k x else return nop
    goE (ApplyE b e)         k = goE e $ \x -> goB b >>= \f -> k (f x)
    goE (UpdateAccum    r e) k = goE e $ \f -> updateAccumRef r f >>= k
    goE (UpdateBehavior r e) _ = goE e $ \x -> do updateBehaviorRef r x; return nop
        -- note: no  k  here because writing behaviors is the end of a path
    goE (Reactimate e)       _ = goE e $ \x -> return x
    goE (ReadCache c ref)    k =
            (c, \_ -> readCacheRef ref >>= maybe (return nop) k)
    goE (WriteCache ref e)   k = goE e $ \x -> writeCacheRef ref x >> k x
    goE (Input channel key)  k =
            (channel, maybe (error "wrong channel") k . fromUniverse key)
    
    nop = return () :: IO ()
    
    goB :: Behavior Linear a -> Run a
    goB = compileBehaviorEvaluation

-- compilation function
compile :: Event Accum () -> IO ([Path], Cache)
compile e = runStore $ runCompile $
    return . map compilePath =<< compileUnion =<< compileReadBehavior e

-- debug :: MonadIO m => String -> m ()
-- debug = liftIO . putStrLn

{-----------------------------------------------------------------------------
    Class instances
------------------------------------------------------------------------------}
-- | The type index 'PushIO' represents the efficient push-driven implementation
-- described here.
-- It implements the same 'FRP' interface as the model implementation
-- represented by 'Model'.
data PushIO

-- type Behavior = Model.Behavior PushIO
newtype instance Model.Behavior PushIO a = Behavior (Behavior Accum a)

-- type Event = Model.Event PushIO
newtype instance Model.Event PushIO a = Event (Event Accum a)

unEvent (Event e) = e

-- sharing
behavior :: BehaviorD Accum a -> Model.Behavior PushIO a
behavior b = Behavior pair
    where
    {-# NOINLINE pair #-}
    -- mention argument to prevent let-floating  
    pair = unsafePerformIO (fmap (,b) newRef)

event :: EventD Accum a -> Model.Event PushIO a
event e = Event pair
    where
    {-# NOINLINE pair #-}
    -- mention argument to prevent let-floating
    pair = unsafePerformIO (fmap (,e) newRef)

-- boilerplate class instances
instance Functor (Model.Event PushIO) where
    fmap f e = apply (pure f) e
    
instance Applicative (Model.Behavior PushIO) where
    pure x = behavior $ Pure x
    (Behavior bf) <*> (Behavior bx) = behavior $ ApplyB bf bx

instance Functor (Model.Behavior PushIO) where
    fmap = liftA

instance FRP PushIO where
    never = event $ Never
    union (Event e1) (Event e2) = event $ Union e1 e2
    filterE p (Event e) = event $ Filter p e
    apply (Behavior bf) (Event ex) = event $ ApplyE bf ex
    accumB x (Event e) = behavior $ AccumB x e
    accumE x (Event e) = event $ AccumE x e

