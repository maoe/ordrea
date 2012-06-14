{-# LANGUAGE DeriveFunctor, GeneralizedNewtypeDeriving, ExistentialQuantification #-}
{-# OPTIONS_GHC -Wall #-}
module Ordrea where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import qualified Data.Char as Char
import Data.IORef
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Data.Ord (comparing)
import qualified Data.Vector.Unboxed as U
import Data.Word
import System.IO.Unsafe
import System.Mem (performGC)
import System.Mem.Weak
import Test.HUnit

import Weak

newtype SignalGen a = SignalGen (ReaderT GEnv IO a)
  deriving (Monad, Functor, Applicative, MonadIO)
type Initialize = ReaderT IEnv IO
type Run = ReaderT REnv IO
type Finalize = IO

data Signal a   = Sig !Priority !(Initialize (Pull a))
data Event a    = Evt !Priority !(Initialize (Pull [a], Notifier))
data Discrete a = Dis !Priority !(Initialize (Pull a, Notifier))

type Consumer a = a -> IO ()

----------------------------------------------------------------------
-- locations and priorities

-- Location of a dynamic node.
type Location = U.Vector Word

-- Priority of updates.
data Priority = Priority
  { priLoc :: {-- UNPACK #-} !Location
  , priNum :: {-# UNPACK #-} !Int
  }
  deriving (Eq, Ord) -- The default lexicographical ordering is appropriate

-- just for debugging
instance Show Priority where
  show Priority{priLoc = loc, priNum = num} =
    show (U.toList loc) ++ "/" ++ show num

nextPrio :: Priority -> Priority
nextPrio prio@Priority{priNum=n} = prio{ priNum = n + 1 }

bottomLocation :: Location
bottomLocation = U.empty

bottomPrio :: Location -> Priority
bottomPrio loc = Priority
  { priLoc = loc
  , priNum = 0
  }

newLocationGen :: Location -> IO (IO Location)
newLocationGen parentLoc = do
  counter <- newRef 0
  return $ do
    num <- readRef counter
    writeRef counter $! num + 1
    return $! parentLoc `U.snoc` num

----------------------------------------------------------------------
-- weak pointers

data WeakKey = forall a. WeakKey {-# UNPACK #-} !(IORef a)

mkWeakWithKey :: WeakKey -> v -> IO (Weak v)
mkWeakWithKey (WeakKey ref) v = mkWeakWithIORef ref v Nothing

----------------------------------------------------------------------
-- SignalGen monad

data GEnv = GEnv
  { envRegisterInit :: Consumer (Initialize ())
  , envGenLocation :: IO Location
  }

runSignalGen :: Location -> Notifier -> SignalGen a -> Run a
runSignalGen parentLoc clock (SignalGen gen) = do
  (registerI, runAccumI) <- liftIO newActionAccum
  locGen <- liftIO $ newLocationGen parentLoc
  let
    genv = GEnv
      { envRegisterInit = registerI
      , envGenLocation = locGen
      }
  result <- liftIO $ runReaderT gen genv
  (_, runAccumF) <- liftIO $ runInit parentLoc clock runAccumI
  isolatingUpdates runAccumF
  return result

genLocation :: SignalGen Location
genLocation = SignalGen $ do
  gen <- asks envGenLocation
  lift gen

registerInit :: Initialize () -> SignalGen ()
registerInit ini = SignalGen $ do
  reg <- asks envRegisterInit
  lift $ reg ini

----------------------------------------------------------------------
-- Initialize monad

data IEnv = IEnv
  { envClock :: Notifier
  , envParentLocation :: Location
  , envRegisterFirstStep :: Consumer (Run ())
  }

registerFirstStep :: Run () -> Initialize ()
registerFirstStep action = do
  reg <- asks envRegisterFirstStep
  lift $ reg action

getClock :: Initialize Notifier
getClock = asks envClock

getParentLocation :: Initialize Location
getParentLocation = asks envParentLocation

runInit :: Location -> Notifier -> Initialize a -> IO (a, Run ())
runInit parentLoc clock i = do
  (registerF, runAccumF) <- newActionAccum
  let
    ienv = IEnv
      { envClock = clock
      , envRegisterFirstStep = registerF
      , envParentLocation = parentLoc
      }
  result <- runReaderT i ienv
  return (result, runAccumF)

----------------------------------------------------------------------
-- Run monad

data REnv = REnv
  { envRegisterFini :: Consumer (Finalize ())
  , envPendingUpdates :: IORef (M.Map Priority (Run ())) -- TODO: use heap?
  }

runRun :: Run a -> IO a
runRun run = do
  (registerF, runAccumF) <- liftIO newActionAccum
  pqueueRef <- newRef M.empty
  let
    renv = REnv
      { envRegisterFini = registerF
      , envPendingUpdates = pqueueRef
      }
  result <- runReaderT (run <* runUpdates) renv
  runAccumF
  return result

runUpdates :: Run ()
runUpdates = asks envPendingUpdates >>= loop
  where
    loop pqueueRef = do
      pending <- readRef pqueueRef
      case M.minView pending of
        Nothing -> return ()
        Just (upd, next) -> do
          writeRef pqueueRef next
          upd :: Run ()
          loop pqueueRef

registerFini :: IO () -> Run ()
registerFini fini = do
  reg <- asks envRegisterFini
  lift $ reg fini

registerUpd :: Priority -> Run () -> Run ()
registerUpd prio upd = do
  pqueueRef <- asks envPendingUpdates
  modifyRef pqueueRef $ M.insertWith' (>>) prio upd

isolatingUpdates :: Run a -> Run a
isolatingUpdates action = do
  pqueueRef <- asks envPendingUpdates
  pqueue <- readRef pqueueRef
  writeRef pqueueRef M.empty
  result <- action
  runUpdates
  writeRef pqueueRef pqueue
  return result

----------------------------------------------------------------------
-- push

type Notifier = Priority -> Weak (Run ()) -> IO ()

listenToNotifier :: WeakKey -> Notifier -> Priority -> (Run ()) -> Initialize ()
listenToNotifier key push prio handler = do
  weak <- liftIO $ mkWeakWithKey key handler
  liftIO $ push prio weak

newNotifier :: IO (Notifier, Run ())
newNotifier = do
  listenersRef <- newRef M.empty
  return (register listenersRef, invoke listenersRef)
  where
    register ref listenerPrio listenerWeak = do
      listenerMap <- readRef ref
      writeRef ref $! M.alter (add listenerWeak) listenerPrio listenerMap
    add weak = Just . (weak:) . fromMaybe []

    invoke ref = do
      m <- readRef ref
      m' <- M.fromList . catMaybes <$> mapM run (M.toList m)
      writeRef ref m'
      where
        run (prio, weaks) = do
          weaks' <- catMaybes <$> mapM run1 weaks
          return $! if null weaks' then Nothing else Just (prio, weaks')
        run1 weak = do
          m <- liftIO $ deRefWeak weak
          case m of
            Just listener -> do
              listener :: Run ()
              return $ Just weak
            Nothing -> return Nothing

emptyNotifier :: Notifier
emptyNotifier _prio _weak = return ()

----------------------------------------------------------------------
-- pull

type Pull a = Run a

newCachedPull :: Initialize (Run a) -> SignalGen (Pull a)
newCachedPull gencalc = do
  actionRef <- newRef (error "newCachedPull: not initialized")
  registerInit $ writeRef actionRef =<< mkpull =<< gencalc
  return $ join $ readRef actionRef
  where
    mkpull calc = do
      ref <- newRef Nothing
      return $ do
        cache <- readRef ref
        case cache of
          Just val -> return val
          Nothing -> do
            val <- calc
            writeRef ref (Just val)
            registerFini $ writeRef ref Nothing
            return val

----------------------------------------------------------------------
-- common push-pull operations

unsafeOnce :: Initialize a -> Initialize a
unsafeOnce = unsafeCache

unsafeProtectFromDup :: (a -> Initialize a) -> Initialize a -> Initialize a
unsafeProtectFromDup protect base = unsafeCache (base >>= protect)

unsafeCache :: Initialize a -> Initialize a
unsafeCache action = do
  cache <- readRef cacheRef
  case cache of
    Just val -> return val
    Nothing -> do
      val <- action
      writeRef cacheRef (Just val)
      return val
  where
    cacheRef = unsafeDupablePerformIO $ newIORef (const' Nothing action)
{-# NOINLINE unsafeCache #-}

-- | Non-inlinable version of const, only useful to prevent optimization.
const' :: a -> b -> a
const' x _ = x
{-# NOINLINE const' #-}

transparentMemo
  :: Priority
  -> Initialize (Pull a, Notifier)
  -> Initialize (Pull a, Notifier)
transparentMemo prio orig = unsafeProtectFromDup (primMemo prio) orig

primMemo :: Priority -> (Pull a, Notifier)
  -> Initialize (Pull a, Notifier)
primMemo prio (pull, notifier) = do
  cacheRef <- newRef $ error "primMemo: cache not initialized"
  listenToPullPush (WeakKey cacheRef) pull notifier prio $ \val -> do
    debug $ "primMemo: writing to cache: prio=" ++ show prio
    writeRef cacheRef val
  let
    readCache = do
      debug $ "primMemo: reading from cache"
      readRef cacheRef
  return (readCache, notifier)
{-# NOINLINE primMemo #-} -- useful for debugging

listenToPullPush
  :: WeakKey
  -> Pull a
  -> Notifier
  -> Priority
  -> (a -> Run ())
  -> Initialize ()
listenToPullPush key pull notifier prio handler = do
  registerFirstStep $ registerUpd prio $ handler =<< pull
    -- ^ use pull for the first step
  listenToNotifier key notifier prio $ handler =<< pull
    -- ^ use push for the subsequent steps

----------------------------------------------------------------------
-- events

instance Functor Event where
  fmap f = transformEvent1 (map f)

instance Monoid (Event a) where
  mempty = emptyEvent
  mappend x y = mergeEvents [x, y]
  mconcat = mergeEvents

listenToEvent :: WeakKey -> Event a -> Priority -> ([a] -> Run ()) -> Initialize ()
listenToEvent key (Evt _ evt) prio handler = do
  (evtPull, evtNot) <- evt
  listenToPullPush key evtPull evtNot prio $ \occs ->
    when (not $ null occs) $ handler occs

newEventSG :: Priority -> SignalGen (Event a, [a] -> Run (), WeakKey)
newEventSG prio = do
  ref <- newRef []
  (push, trigger) <- liftIO newNotifier
  let evt = Evt prio $ return (eventPull ref, push)
  return (evt, eventTrigger ref trigger, WeakKey ref)

newEventInit :: Initialize ((Pull [a], Notifier), [a] -> Run (), WeakKey)
newEventInit = do
  ref <- newRef []
  (push, trigger) <- liftIO newNotifier
  return ((eventPull ref, push), eventTrigger ref trigger, WeakKey ref)

eventPull :: IORef [a] -> Pull [a]
eventPull buf = readRef buf

eventTrigger :: IORef [a] -> Run () -> [a] -> Run ()
eventTrigger buf notify occs = do
  writeRef buf occs
  registerFini $ writeRef buf []
  notify

transformEvent :: ([a] -> [b]) -> Event a -> Event b
transformEvent f parent@(Evt evprio _) = Evt prio $ transparentMemo memoprio $ do
  (pullpush, trigger, key) <- newEventInit
  listenToEvent key parent prio $ \xs -> case f xs of
    [] -> return ()
    ys -> trigger ys
  return pullpush
  where
    memoprio = nextPrio evprio
    prio = nextPrio memoprio

transformEvent1 :: ([a] -> [b]{-non-empty-}) -> Event a -> Event b
transformEvent1 f (Evt evprio evt) = Evt prio $ transparentMemo memoprio $ do
  (pull, notifier) <- evt
  return (f <$> pull, notifier)
  where
    memoprio = nextPrio evprio
    prio = nextPrio memoprio

generatorE :: Event (SignalGen a) -> SignalGen (Event a)
generatorE evt = do
  here <- genLocation
  let prio = bottomPrio here
  (result, trigger, key) <- newEventSG prio
  registerInit $ do
    clock <- getClock
    listenToEvent key evt prio $ \gens ->
      trigger =<< mapM (runSignalGen here clock) gens
  return $ result

mergeEvents :: [Event a] -> Event a
mergeEvents [] = emptyEvent
mergeEvents evts = Evt prio $ unsafeOnce $ do
  (pullpush, trigger, key) <- newEventInit
  occListRef <- newRef []
  let
    upd = do
      occList <- readRef occListRef
      debug $ "mergeEvents: upd: prio=" ++ show prio ++ "; total occs=" ++ show (length $ concatMap snd occList)
      when (not $ null occList) $ do
        writeRef occListRef []
        trigger $ concatMap snd $ sortBy (comparing fst) occList
  forM_ (zip [0::Int ..] evts) $ \(num, evt) ->
    listenToEvent key evt prio $ \occs -> do
      debug $ "mergeEvents: listen: noccs=" ++ show (length occs)
      modifyRef occListRef ((num, occs):)
      registerUpd prio upd
  return pullpush
  where
    prio = maximum $ map evtPrio evts
    evtPrio (Evt p _) = p

emptyEvent :: Event a
emptyEvent = Evt (bottomPrio bottomLocation) $ return (return [], emptyNotifier)

filterE :: (a -> Bool) -> Event a -> Event a
filterE p = transformEvent (filter p)

stepClockE :: Event ()
stepClockE = Evt (bottomPrio bottomLocation) $ do
  clock <- getClock
  return (pure [()], clock)

dropStepE :: Event a -> SignalGen (Event a)
dropStepE evt@(Evt evtprio _) = do
  clockKey <- WeakKey <$> newRef ()
  clockKeyRef <- newRef (Just clockKey)
  (result, trigger, key) <- newEventSG prio

  registerInit $ do
    clock <- getClock
    listenToNotifier clockKey clock prio $ writeRef clockKeyRef Nothing
    listenToEvent key evt prio $ \occs -> do
      firstStep <- isJust <$> readRef clockKeyRef
      when (not firstStep) $ trigger occs

  return result
  where
    prio = nextPrio evtprio

eventFromList :: [[a]] -> SignalGen (Event a)
eventFromList occs = signalToEvent <$> signalFromList (occs ++ repeat [])

----------------------------------------------------------------------
-- discretes

instance Functor Discrete where
  fmap = mapDiscrete

instance Applicative Discrete where
  pure = pureDiscrete
  (<*>) = apDiscrete

newDiscreteInit :: a -> Initialize ((Pull a, Notifier), a -> Run (), WeakKey)
newDiscreteInit initial = do
  ref <- newRef initial
  (push, trigger) <- liftIO newNotifier
  return ((readRef ref, push), discreteTrigger ref trigger, WeakKey ref)

newDiscreteSG :: a -> Priority -> SignalGen (Discrete a, Run a, a -> Run (), WeakKey)
newDiscreteSG initial prio = do
  ref <- newRef initial
  (push, trigger) <- liftIO newNotifier
  let dis = Dis prio $ return (readRef ref, push)
  return (dis, readRef ref, discreteTrigger ref trigger, WeakKey ref)

discreteTrigger :: IORef a -> Run () -> a -> Run ()
discreteTrigger buf notify val = do
  writeRef buf val
  notify

mapDiscrete :: (a -> b) -> Discrete a -> Discrete b
mapDiscrete f (Dis dprio dis) = Dis prio $ transparentMemo memoprio $ do
  (pull, notifier) <- dis
  return (f <$> pull, notifier)
  where
    prio = nextPrio memoprio
    memoprio = nextPrio dprio

pureDiscrete :: a -> Discrete a
pureDiscrete value = Dis (bottomPrio bottomLocation) $
  return (pure value, emptyNotifier)

apDiscrete :: Discrete (a -> b) -> Discrete a -> Discrete b
-- both arguments must have been memoized
apDiscrete (Dis fprio fun) (Dis aprio arg)
    = Dis prio $ transparentMemo memoprio $ do
  dirtyRef <- newRef False
  (pullpush, set, key) <- newDiscreteInit (error "apDiscrete: uninitialized")
  (funPull, funNot) <- fun
  (argPull, argNot) <- arg
  let
    upd = do
      dirty <- readRef dirtyRef
      when dirty $ do
        writeRef dirtyRef False
        set =<< funPull <*> argPull
  let handler = writeRef dirtyRef True >> registerUpd prio upd
  listenToNotifier key funNot prio handler
  listenToNotifier key argNot prio handler
  return pullpush
  where
    srcprio = max fprio aprio
    memoprio = nextPrio srcprio
    prio = nextPrio memoprio

listenToDiscrete :: WeakKey -> Discrete a -> Priority -> (a -> Run ()) -> Initialize ()
listenToDiscrete key (Dis _ dis) prio handler = do
  (disPull, disNot) <- dis
  listenToPullPush key disPull disNot prio handler

----------------------------------------------------------------------
-- signals

instance Functor Signal where
  fmap f (Sig prio pull) = Sig prio (fmap f <$> pull) -- TODO: memoize

start :: SignalGen (Signal a) -> IO (IO a)
start gensig = do
  (clock, clockTrigger) <- newNotifier
  getval <- runRun $ do
    ref <- newRef undefined
    runSignalGen bottomLocation clock $ do
      Sig _ sig <- gensig
      registerInit $ do
        getval <- sig
        writeRef ref getval
    readRef ref
  return $ runRun $ do
    isolatingUpdates clockTrigger
    getval

externalS :: IO a -> SignalGen (Signal a)
externalS get = do
  pull <- newCachedPull $ return $ liftIO get
  return $ Sig (bottomPrio bottomLocation) $ return pull

joinS :: Signal (Signal a) -> SignalGen (Signal a)
joinS ~(Sig _sigsigprio sigsig) = do
  here <- genLocation
  let prio = bottomPrio here
  pull <- newCachedPull $ do
    parLoc <- getParentLocation
    clock <- getClock
    sigpull <- sigsig
    return $ do
      Sig _sigprio sig <- sigpull
      (pull, first) <- liftIO $ runInit parLoc clock sig
      first
      pull
  return $! Sig prio $ return pull

delayS :: a -> Signal a -> SignalGen (Signal a)
delayS initial ~(Sig _sigprio sig) = do
  ref <- newRef initial
  registerInit $ do
    clock <- getClock
    pull <- sig
    listenToNotifier (WeakKey ref) clock prio $ do
      newVal <- pull
      registerFini $ writeRef ref newVal
  return $ Sig prio $ return $ readRef ref
  where
    prio = bottomPrio bottomLocation

signalFromList :: [a] -> SignalGen (Signal a)
signalFromList xs = do
  clock <- dropStepE stepClockE
  suffixD <- accumD xs $ drop 1 <$ clock
  return $ discreteToSignal $ hd <$> suffixD
  where
    hd = fromMaybe (error "listToSignal: list exhausted") .
      listToMaybe

networkToList :: Int -> SignalGen (Signal a) -> IO [a]
networkToList count network = do
  smp <- start network
  replicateM count smp

networkToListGC :: Int -> SignalGen (Signal a) -> IO [a]
networkToListGC count network = do
  smp <- start network
  replicateM count (performGC >> smp)

----------------------------------------------------------------------
-- events and discretes

accumD :: a -> Event (a -> a) -> SignalGen (Discrete a)
accumD initial evt@(~(Evt evtprio _)) = do
  (dis, get, set, key) <- newDiscreteSG initial prio
  registerInit $ listenToEvent key evt prio $ \occs -> do
    oldVal <- get
    set $! foldl' (flip ($)) oldVal occs
  return dis
  where
    prio = nextPrio evtprio

changesD :: Discrete a -> Event a
changesD (Dis disprio dis) = Evt prio $ unsafeOnce $ do
  (pullpush, trigger, key) <- newEventInit
  (dispull, notifier) <- dis
  listenToNotifier key notifier prio $ trigger . (:[]) =<< dispull
  return pullpush
  where
    prio = nextPrio disprio

----------------------------------------------------------------------
-- events and signals

eventToSignal :: Event a -> Signal [a]
eventToSignal (Evt prio evt) = Sig prio $ do
  (pull, _push) <- evt
  return pull

signalToEvent :: Signal [a] -> Event a
signalToEvent (Sig sigprio sig) = Evt prio $ unsafeCache $ do
  debug "signalToEvent"
  sigpull <- sig
  (pullpush, trigger, key) <- newEventInit
    -- ^ Here we create a fresh event, even though its pull component
    -- will be identical to sigpull. This is because we want a new key
    -- to keep the new notifier alive as long as the new pull, rather
    -- than the original pull, is alive.
  clock <- getClock
  listenToNotifier key clock prio $ do
    occs <- sigpull
    debug $ "signalToEvent: onclock prio=" ++ show prio ++ "; noccs=" ++ show (length occs)
    when (not $ null occs) $ trigger occs
  return pullpush
  where
    prio = nextPrio sigprio

----------------------------------------------------------------------
-- discretes and signals

discreteToSignal :: Discrete a -> Signal a
discreteToSignal (Dis prio dis) = Sig prio $ fst <$> dis

----------------------------------------------------------------------
-- utils

newRef :: (MonadIO m) => a -> m (IORef a)
newRef = liftIO . newIORef

readRef :: (MonadIO m) => IORef a -> m a
readRef = liftIO . readIORef

writeRef :: (MonadIO m) => IORef a -> a -> m ()
writeRef x v = liftIO $ writeIORef x v

modifyRef :: (MonadIO m) => IORef a -> (a -> a) -> m ()
modifyRef x f = do
  old <- readRef x
  writeRef x $! f old

-- TODO: specialize
newActionAccum :: (MonadIO m) => IO (Consumer (m ()), m ())
newActionAccum = do
  actions <- newRef []
  return (add actions, run actions)
  where
    add ref act = modifyIORef ref (act:)
    run ref = readRef ref >>= sequence_

debug :: (MonadIO m) => String -> m ()
debug str = when debugTraceEnabled $ liftIO $ putStrLn str

debugTraceEnabled :: Bool
debugTraceEnabled = False

----------------------------------------------------------------------
-- tests

_unitTest :: IO Counts
_unitTest = runTestTT $ test
  [ test_signalFromList
  , test_accumD
  , test_changesD
  , test_mappendEvent
  , test_fmapEvent
  , test_filterE
  , test_dropStepE
  , test_apDiscrete
  , test_eventFromList
  ]
  where
    test_signalFromList = do
      r <- networkToList 4 $ signalFromList ["foo", "bar", "baz", "quux"]
      r @?= ["foo", "bar", "baz", "quux"]

    test_accumD = do
      r <- networkToList 3 $ do
        strS <- signalFromList ["foo", "", "baz"]
        accD <- accumD "<>" $ append <$> signalToEvent strS
        return $ discreteToSignal accD
      r @?= ["<>/'f'/'o'/'o'", "<>/'f'/'o'/'o'", "<>/'f'/'o'/'o'/'b'/'a'/'z'"]
      where
        append ch str = str ++ "/" ++ show ch

    test_changesD = do
      r <- networkToList 3 $ do
        strS <- signalFromList ["foo", "", "baz"]
        accD <- accumD "<>" $ append <$> signalToEvent strS
        return $ eventToSignal $ changesD accD
      r @?= [["<>/'f'/'o'/'o'"], [], ["<>/'f'/'o'/'o'/'b'/'a'/'z'"]]
      where
        append ch str = str ++ "/" ++ show ch

    test_mappendEvent = do
      r <- networkToListGC 3 $ do
        strS <- signalFromList ["foo", "", "baz"]
        accD <- accumD "<>" $ append <$> signalToEvent strS
        return $ eventToSignal $
          changesD accD `mappend` (signalToEvent $ (:[]) <$> strS)
      r @?= [["<>/'f'/'o'/'o'", "foo"], [""], ["<>/'f'/'o'/'o'/'b'/'a'/'z'", "baz"]]
      where
        append ch str = str ++ "/" ++ show ch

    test_fmapEvent = do
      succCountRef <- newRef (0::Int)
      r <- networkToListGC 3 $ do
        strS <- signalFromList ["foo", "", "baz"]
        let lenE = mysucc succCountRef <$> signalToEvent strS
        return $ eventToSignal $ lenE `mappend` lenE
      r @?= ["gppgpp", "", "cb{cb{"]
      count <- readRef succCountRef
      count @?= 6
      where
        {-# NOINLINE mysucc #-}
        mysucc ref c = unsafePerformIO $ do
          modifyRef ref (+1)
          return $ succ c

    test_filterE = do
      r <- networkToListGC 3 $ do
        strS <- signalFromList ["FOo", "", "bAz"]
        let lenE = filterE Char.isUpper $ signalToEvent strS
        return $ eventToSignal $ lenE `mappend` lenE
      r @?= ["FOFO", "", "AA"]

    test_dropStepE = do
      r <- networkToListGC 3 $ do
        strS <- signalFromList ["foo", "", "baz"]
        lenE <- dropStepE $ signalToEvent strS
        return $ eventToSignal $ lenE `mappend` lenE
      r @?= ["", "", "bazbaz"]

    test_apDiscrete = do
      r <- networkToListGC 4 $ do
        ev0 <- signalToEvent <$> signalFromList [[1::Int], [], [], [2,3]]
        ev1 <- signalToEvent <$> signalFromList [[], [4], [], [5]]
        dis0 <- accumD 0 $ max <$> ev0
        dis1 <- accumD 0 $ max <$> ev1
        let dis = (*) <$> dis0 <*> dis1
        return $ eventToSignal $ changesD dis
      r @?= [[0], [4], [], [15]]

    test_eventFromList = do
      r <- networkToListGC 3 $ do
        ev <- eventFromList [[2::Int], [], [3,4]]
        return $ eventToSignal ev
      r @?= [[2], [], [3,4]]

-- vim: sw=2 ts=2 sts=2
