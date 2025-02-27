-- | The set of wallets utxos selected as inputs for any subsequent transaction
-- | might actually be already submitted by a previous one and pending
-- | to be spent.
-- | This module provides a simple, in-memory cache that helps with keeping
-- | submitted utxos in-check.
module Types.UsedTxOuts
  ( UsedTxOuts(UsedTxOuts)
  , TxOutRefCache
  , isTxOutRefUsed
  , lockTransactionInputs
  , newUsedTxOuts
  , unlockTxOutRefs
  , unlockTransactionInputs
  ) where

import Control.Alt ((<$>))
import Control.Alternative (guard, pure)
import Control.Bind (bind, (=<<), (>>=))
import Control.Category ((<<<), (>>>))
import Control.Monad.RWS (ask)
import Control.Monad.Reader (class MonadAsk)
import Data.Foldable (class Foldable, foldr)
import Data.Function (($))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe
  ( Maybe(Just, Nothing)
  , fromMaybe
  , isJust
  )
import Data.Newtype (class Newtype, unwrap)
import Data.Set (Set)
import Data.Set as Set
import Data.UInt (UInt)
import Data.Unit (Unit)
import Effect.Class
  ( class MonadEffect
  , liftEffect
  )
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Types.Transaction
  ( Transaction
  , TransactionHash
  )

type TxOutRefCache = Map TransactionHash (Set UInt)

-- | Stores TxOutRefs in a compact map.
newtype UsedTxOuts = UsedTxOuts (Ref TxOutRefCache)

derive instance Newtype UsedTxOuts _

-- | Creates a new empty filter.
newUsedTxOuts
  :: forall (m :: Type -> Type) (t :: Type -> Type)
   . MonadEffect m
  => m UsedTxOuts
newUsedTxOuts = UsedTxOuts <$> liftEffect (Ref.new Map.empty)

-- | Mark transaction's inputs as used.
lockTransactionInputs
  :: forall (m :: Type -> Type)
   . MonadAsk UsedTxOuts m
  => MonadEffect m
  => Transaction
  -> m Unit
lockTransactionInputs tx =
  let
    updateCache :: TxOutRefCache -> TxOutRefCache
    updateCache cache = foldr
      ( \{ transactionId, index } ->
          Map.alter (fromMaybe Set.empty >>> Set.insert index >>> Just)
            transactionId
      )
      cache
      (txOutRefs tx)
  in
    ask >>= (unwrap >>> Ref.modify_ updateCache >>> liftEffect)

-- | Remove transaction's inputs used marks.
unlockTransactionInputs
  :: forall (m :: Type -> Type)
   . MonadAsk UsedTxOuts m
  => MonadEffect m
  => Transaction
  -> m Unit
unlockTransactionInputs = txOutRefs >>> unlockTxOutRefs

-- | Remove used marks from TxOutRefs given directly.
unlockTxOutRefs
  :: forall (m :: Type -> Type) (t :: Type -> Type) (a :: Type)
   . MonadAsk UsedTxOuts m
  => MonadEffect m
  => Foldable t
  => t { transactionId :: TransactionHash, index :: UInt }
  -> m Unit
unlockTxOutRefs txOutRefs' =
  let
    updateCache :: TxOutRefCache -> TxOutRefCache
    updateCache cache = foldr
      ( \{ transactionId, index } ->
          Map.update
            ( Set.delete index >>> \s ->
                if Set.isEmpty s then Nothing else Just s
            )
            transactionId
      )
      cache
      txOutRefs'
  in
    ask >>= (unwrap >>> Ref.modify_ updateCache >>> liftEffect)

-- | Query if TxOutRef is marked as used.
isTxOutRefUsed
  :: forall (m :: Type -> Type) (a :: Type)
   . MonadAsk UsedTxOuts m
  => MonadEffect m
  => { transactionId :: TransactionHash, index :: UInt }
  -> m Boolean
isTxOutRefUsed { transactionId, index } = do
  cache <- liftEffect <<< Ref.read <<< unwrap =<< ask
  pure $ isJust $ do
    indices <- Map.lookup transactionId cache
    guard $ Set.member index indices

txOutRefs
  :: Transaction -> Array { transactionId :: TransactionHash, index :: UInt }
txOutRefs tx = unwrap <$> (unwrap (unwrap tx).body).inputs
