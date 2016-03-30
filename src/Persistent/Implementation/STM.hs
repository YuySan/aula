{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE ImpredicativeTypes          #-}
{-# LANGUAGE OverloadedStrings           #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE TypeOperators               #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Persistent.Implementation.STM
    ( Persist
    , mkRunPersist
    )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, modifyTVar')
import Control.Lens
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Reader (ReaderT(ReaderT), runReaderT)
import Servant.Server ((:~>)(Nat))

import Types
import Persistent.Api

-- FIXME: Remove
import Test.QuickCheck (generate)

newtype Persist a = Persist (ReaderT (TVar AulaData) IO a)
  deriving (Functor, Applicative, Monad)

persistIO :: IO a -> Persist a
persistIO = Persist . liftIO

instance GenArbitrary Persist where
    genGen = persistIO . generate

mkRunPersist :: IO (Persist :~> IO)
mkRunPersist = do
    tvar <- newTVarIO emptyAulaData
    let run (Persist c) = c `runReaderT` tvar
    return $ Nat run

instance MonadIO Persist where
    liftIO = persistIO

instance PersistM Persist where
    getDb l = Persist . ReaderT $ fmap (view l) . atomically . readTVar
    modifyDb l f = Persist . ReaderT $ \state -> atomically $ modifyTVar' state (l %~ f)
