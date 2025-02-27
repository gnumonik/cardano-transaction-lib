module BalanceTx
  ( Actual(..)
  , AddTxCollateralsError(..)
  , BalanceNonAdaOutsError(..)
  , BalanceTxError(..)
  , BalanceTxInsError(..)
  , CannotMinusError(..)
  , Expected(..)
  , GetPublicKeyTransactionInputError(..)
  , GetWalletAddressError(..)
  , GetWalletCollateralError(..)
  , ImpossibleError(..)
  , ReturnAdaChangeError(..)
  , UtxosAtError(..)
  , balanceTx
  ) where

import Prelude

import Control.Monad.Except.Trans (ExceptT(ExceptT), except, runExceptT)
import Control.Monad.Logger.Class (class MonadLogger)
import Control.Monad.Logger.Class as Logger
import Control.Monad.Reader.Class (asks)
import Data.Array ((\\), findIndex, modifyAt)
import Data.Array as Array
import Data.Bifunctor (lmap, rmap)
import Data.BigInt (BigInt, fromInt, quot)
import Data.Either (Either(Left, Right), hush, note)
import Data.Foldable as Foldable
import Data.Generic.Rep (class Generic)
import Data.Lens.Getter ((^.))
import Data.Lens.Setter ((.~), (%~))
import Data.List ((:), List(Nil), partition)
import Data.Log.Tag (tag)
import Data.Map as Map
import Data.Maybe (fromMaybe, maybe, Maybe(Just, Nothing))
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Show.Generic (genericShow)
import Data.Traversable (traverse_)
import Data.Tuple (fst)
import Data.Tuple.Nested ((/\), type (/\))
import Effect.Class (class MonadEffect)
import ProtocolParametersAlonzo
  ( adaOnlyWords
  , coinSize
  , lovelacePerUTxOWord
  , pidSize
  , protocolParamUTxOCostPerWord
  , utxoEntrySizeWithoutVal
  )
import QueryM
  ( ClientError
  , QueryM
  , calculateMinFee
  , getWalletAddress
  , getWalletCollateral
  )
import QueryM.Utxos (utxosAt)
import Serialization.Address
  ( Address
  , addressPaymentCred
  , withStakeCredential
  )
import Types.Transaction
  ( DataHash
  , Transaction(Transaction)
  , TransactionInput
  , TransactionOutput(TransactionOutput)
  , TxBody(TxBody)
  , Utxo
  , _body
  , _inputs
  , _networkId
  )
import Types.TransactionUnspentOutput (TransactionUnspentOutput)
import Types.UnbalancedTransaction (UnbalancedTx(UnbalancedTx))
import Cardano.Types.Value
  ( filterNonAda
  , geq
  , getLovelace
  , lovelaceValueOf
  , isAdaOnly
  , isPos
  , isZero
  , minus
  , mkCoin
  , mkValue
  , numCurrencySymbols
  , numTokenNames
  , sumTokenNameLengths
  , valueToCoin
  , Value
  )
import TxOutput (utxoIndexToUtxo)

-- This module replicates functionality from
-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs

--------------------------------------------------------------------------------
-- Errors for Balancing functions
--------------------------------------------------------------------------------
-- These derivations may need tweaking when testing to make sure they are easy
-- to read, especially with generic show vs newtype show derivations.
data BalanceTxError
  = GetWalletAddressError' GetWalletAddressError
  | GetWalletCollateralError' GetWalletCollateralError
  | UtxosAtError' UtxosAtError
  | ReturnAdaChangeError' ReturnAdaChangeError
  | AddTxCollateralsError' AddTxCollateralsError
  | GetPublicKeyTransactionInputError' GetPublicKeyTransactionInputError
  | BalanceTxInsError' BalanceTxInsError
  | BalanceNonAdaOutsError' BalanceNonAdaOutsError
  | CalculateMinFeeError' ClientError

derive instance genericBalanceTxError :: Generic BalanceTxError _

instance showBalanceTxError :: Show BalanceTxError where
  show = genericShow

data GetWalletAddressError = CouldNotGetNamiWalletAddress

derive instance genericGetWalletAddressError :: Generic GetWalletAddressError _

instance showGetWalletAddressError :: Show GetWalletAddressError where
  show = genericShow

data GetWalletCollateralError = CouldNotGetNamiCollateral

derive instance genericGetWalletCollateralError ::
  Generic GetWalletCollateralError _

instance showGetWalletCollateralError :: Show GetWalletCollateralError where
  show = genericShow

data UtxosAtError = CouldNotGetUtxos

derive instance genericUtxosAtError :: Generic UtxosAtError _

instance showUtxosAtError :: Show UtxosAtError where
  show = genericShow

data ReturnAdaChangeError
  = ReturnAdaChangeError String
  | ReturnAdaChangeImpossibleError String ImpossibleError
  | ReturnAdaChangeCalculateMinFee ClientError

derive instance genericReturnAdaChangeError :: Generic ReturnAdaChangeError _

instance showReturnAdaChangeError :: Show ReturnAdaChangeError where
  show = genericShow

data AddTxCollateralsError = CollateralUtxosUnavailable

derive instance genericAddTxCollateralsError :: Generic AddTxCollateralsError _

instance showAddTxCollateralsError :: Show AddTxCollateralsError where
  show = genericShow

data GetPublicKeyTransactionInputError = CannotConvertScriptOutputToTxInput

derive instance genericGetPublicKeyTransactionInputError ::
  Generic GetPublicKeyTransactionInputError _

instance showGetPublicKeyTransactionInputError ::
  Show GetPublicKeyTransactionInputError where
  show = genericShow

data BalanceTxInsError
  = InsufficientTxInputs Expected Actual
  | BalanceTxInsCannotMinus CannotMinusError

derive instance genericBalanceTxInsError :: Generic BalanceTxInsError _

instance showBalanceTxInsError :: Show BalanceTxInsError where
  show = genericShow

data CannotMinusError = CannotMinus Actual

derive instance genericCannotMinusError :: Generic CannotMinusError _

instance showCannotMinusError :: Show CannotMinusError where
  show = genericShow

data CollectTxInsError = CollectTxInsInsufficientTxInputs BalanceTxInsError

derive instance genericCollectTxInsError :: Generic CollectTxInsError _

instance showCollectTxInsError :: Show CollectTxInsError where
  show = genericShow

newtype Expected = Expected Value

derive instance genericExpected :: Generic Expected _
derive instance newtypeExpected :: Newtype Expected _

instance showExpected :: Show Expected where
  show = genericShow

newtype Actual = Actual Value

derive instance genericActual :: Generic Actual _
derive instance newtypeActual :: Newtype Actual _

instance showActual :: Show Actual where
  show = genericShow

data BalanceNonAdaOutsError
  = InputsCannotBalanceNonAdaTokens
  | BalanceNonAdaOutsCannotMinus CannotMinusError

derive instance genericBalanceNonAdaOutsError ::
  Generic BalanceNonAdaOutsError _

instance showBalanceNonAdaOutsError :: Show BalanceNonAdaOutsError where
  show = genericShow

-- | Represents that an error reason should be impossible
data ImpossibleError = Impossible

derive instance genericImpossibleError :: Generic ImpossibleError _

instance showImpossibleError :: Show ImpossibleError where
  show = genericShow

--------------------------------------------------------------------------------
-- Type aliases, temporary placeholder types and functions
--------------------------------------------------------------------------------
-- Output utxos with the amount of lovelaces required.
type MinUtxos = Array (TransactionOutput /\ BigInt)

calculateMinFee'
  :: Transaction
  -> QueryM (Either ClientError BigInt)
calculateMinFee' = calculateMinFee >>> map (rmap unwrap)

--------------------------------------------------------------------------------
-- Balancing functions and helpers
--------------------------------------------------------------------------------
-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs#L54
-- FIX ME: UnbalancedTx contains requiredSignatories which would be a part of
-- multisig but we don't have such functionality ATM.

-- | Balances an unbalanced transaction. For submitting a tx via Nami, the
-- utxo set shouldn't include the collateral which is vital for balancing.
-- In particular, the transaction inputs must not include the collateral.
balanceTx :: UnbalancedTx -> QueryM (Either BalanceTxError Transaction)
balanceTx (UnbalancedTx { transaction: unbalancedTx, utxoIndex }) = do
  networkId <- (unbalancedTx ^. _body <<< _networkId) #
    maybe (asks _.networkId) pure
  let unbalancedTx' = unbalancedTx # _body <<< _networkId .~ Just networkId
  runExceptT do
    -- Get own wallet address, collateral and utxo set:
    ownAddr <- ExceptT $ getWalletAddress <#>
      note (GetWalletAddressError' CouldNotGetNamiWalletAddress)
    collateral <- ExceptT $ getWalletCollateral <#>
      note (GetWalletCollateralError' CouldNotGetNamiCollateral)
    utxos <- ExceptT $ utxosAt ownAddr <#>
      (note (UtxosAtError' CouldNotGetUtxos) >>> map unwrap)

    let
      -- Combines utxos at the user address and those from any scripts
      -- involved with the contract in the unbalanced transaction.
      allUtxos :: Utxo
      allUtxos = utxos `Map.union` utxoIndexToUtxo networkId utxoIndex

      -- After adding collateral, we need to balance the inputs and
      -- non-Ada outputs before looping, i.e. we need to add input fees
      -- for the Ada only collateral. No MinUtxos required. In fact perhaps
      -- this step can be skipped and we can go straight to prebalancer.
      unbalancedCollTx :: Transaction
      unbalancedCollTx = addTxCollateral unbalancedTx' collateral

    -- Logging Unbalanced Tx with collateral added:
    logTx' "Unbalanced Collaterised Tx " allUtxos unbalancedCollTx

    -- Prebalance collaterised tx without fees:
    ubcTx <- except $
      prebalanceCollateral zero allUtxos ownAddr unbalancedCollTx
    -- Prebalance collaterised tx with fees:
    fees <- ExceptT $ calculateMinFee' ubcTx <#> lmap CalculateMinFeeError'
    ubcTx' <- except $
      prebalanceCollateral (fees + feeBuffer) allUtxos ownAddr ubcTx

    -- Loop to balance non-Ada assets
    nonAdaBalancedCollTx <- ExceptT $ loop allUtxos ownAddr [] ubcTx'
    -- Return excess Ada change to wallet:
    unsignedTx <- ExceptT $
      returnAdaChange ownAddr allUtxos nonAdaBalancedCollTx <#>
        lmap ReturnAdaChangeError'

    -- Sort inputs at the very end so it behaves as a Set.
    let sortedUnsignedTx = unsignedTx # _body <<< _inputs %~ Array.sort
    -- Logs final balanced tx and returns it
    ExceptT $ logTx "Post-balancing Tx " allUtxos sortedUnsignedTx <#> Right
  where
  prebalanceCollateral
    :: BigInt
    -> Utxo
    -> Address
    -> Transaction
    -> Either BalanceTxError Transaction
  prebalanceCollateral
    fees'
    utxoIndex'
    ownAddr'
    oldTx'@(Transaction { body: txBody }) =
    balanceTxIns utxoIndex' fees' txBody
      >>= balanceNonAdaOuts ownAddr' utxoIndex'
      >>= \txBody' -> pure $ wrap (unwrap oldTx') { body = txBody' }

  loop
    :: Utxo
    -> Address
    -> MinUtxos
    -> Transaction
    -> QueryM (Either BalanceTxError Transaction)
  loop
    utxoIndex'
    ownAddr'
    prevMinUtxos'
    tx''@(Transaction tx'@{ body: txBody'@(TxBody txB) }) = do
    let
      nextMinUtxos' :: MinUtxos
      nextMinUtxos' =
        calculateMinUtxos $ txB.outputs \\ map fst prevMinUtxos'

      minUtxos' :: MinUtxos
      minUtxos' = prevMinUtxos' <> nextMinUtxos'

    balancedTxBody' <- chainedBalancer minUtxos' utxoIndex' ownAddr' tx''

    case balancedTxBody' of
      Left err -> pure $ Left err
      Right balancedTxBody'' ->
        if txBody' == balancedTxBody'' then
          pure $ Right $ wrap tx' { body = balancedTxBody'' }
        else
          loop
            utxoIndex'
            ownAddr'
            minUtxos'
            $ wrap tx' { body = balancedTxBody'' }

  chainedBalancer
    :: MinUtxos
    -> Utxo
    -> Address
    -> Transaction
    -> QueryM (Either BalanceTxError TxBody)
  chainedBalancer
    minUtxos'
    utxoIndex'
    ownAddr'
    (Transaction tx'@{ body: txBody' }) =
    runExceptT do
      txBodyWithoutFees' <- except $ preBalanceTxBody
        minUtxos'
        zero
        utxoIndex'
        ownAddr'
        txBody'
      let tx'' = wrap tx' { body = txBodyWithoutFees' }
      fees' <- ExceptT $ calculateMinFee' tx'' <#> lmap CalculateMinFeeError'
      except $ preBalanceTxBody
        minUtxos'
        (fees' + feeBuffer) -- FIX ME: Add 0.5 Ada to ensure enough input for later on in final balancing.
        utxoIndex'
        ownAddr'
        txBody'

  -- We expect the user has a minimum amount of Ada (this buffer) on top of
  -- their transaction, so by the time the prebalancer finishes, should it
  -- succeed, there will be some excess Ada (since all non Ada is balanced).
  -- In particular, this excess Ada will be at least this buffer. This is
  -- important for when returnAdaChange is called to return Ada change back
  -- to the user. The idea is this buffer provides enough so that returning
  -- excess Ada is covered by two main scenarios (see returnAdaChange for more
  -- details):
  -- 1) A new utxo doesn't need to be created (no extra fees).
  -- 2) A new utxo needs to be created but the buffer provides enough Ada to
  -- create the utxo, cover any extra fees without a further need for looping.
  -- This buffer could potentially be calculated exactly using (the Haskell server)
  -- https://github.com/input-output-hk/plutus/blob/8abffd78abd48094cfc72f1ad7b81b61e760c4a0/plutus-core/untyped-plutus-core/src/UntypedPlutusCore/Evaluation/Machine/Cek/Internal.hs#L723
  -- The trade off for this set up is any transaction requires this buffer on
  -- top of their transaction as input.
  feeBuffer :: BigInt
  feeBuffer = fromInt 500000

-- Logging for Transaction type without returning Transaction
logTx'
  :: forall (m :: Type -> Type)
   . MonadEffect m
  => MonadLogger m
  => String
  -> Utxo
  -> Transaction
  -> m Unit
logTx' msg utxos (Transaction { body: body'@(TxBody body) }) =
  traverse_ (Logger.trace (tag msg mempty))
    [ "Input Value: " <> show (getInputValue utxos body')
    , "Output Value: " <> show (Array.foldMap getAmount body.outputs)
    , "Fees: " <> show body.fee
    ]

-- Logging for Transaction type returning Transaction
logTx
  :: forall (m :: Type -> Type)
   . MonadEffect m
  => MonadLogger m
  => String
  -> Utxo
  -> Transaction
  -> m Transaction
logTx msg utxo tx = logTx' msg utxo tx *> pure tx

-- Nami provides a 5 Ada collateral that we should add the tx before balancing
addTxCollateral :: Transaction -> TransactionUnspentOutput -> Transaction
addTxCollateral (Transaction tx@{ body: TxBody txBody }) txUnspentOutput =
  wrap tx
    { body = wrap txBody
        { collateral = pure $ Array.singleton $ (unwrap txUnspentOutput).input }
    }

-- Transaction should be prebalanced at this point with all excess with Ada
-- where the Ada value of inputs is greater or equal to value of outputs.
-- Also add fees to txBody. This should be called with a Tx with min
-- Ada in each output utxo, namely, after "loop".
returnAdaChange
  :: Address
  -> Utxo
  -> Transaction
  -> QueryM (Either ReturnAdaChangeError Transaction)
returnAdaChange changeAddr utxos (Transaction tx@{ body: TxBody txBody }) =
  runExceptT do
    fees <- ExceptT $ calculateMinFee' (wrap tx) <#>
      lmap ReturnAdaChangeCalculateMinFee
    let
      txOutputs :: Array TransactionOutput
      txOutputs = txBody.outputs

      inputValue :: Value
      inputValue = getInputValue utxos (wrap txBody)

      inputAda :: BigInt
      inputAda = getLovelace $ valueToCoin inputValue

      -- FIX ME, ignore mint value?
      outputValue :: Value
      outputValue = Array.foldMap getAmount txOutputs

      outputAda :: BigInt
      outputAda = getLovelace $ valueToCoin outputValue

      returnAda :: BigInt
      returnAda = inputAda - outputAda - fees
    case compare returnAda zero of
      LT ->
        except $ Left $
          ReturnAdaChangeImpossibleError
            "Not enough Input Ada to cover output and fees after prebalance."
            Impossible
      EQ -> except $ Right $ wrap tx { body = wrap txBody { fee = wrap fees } }
      GT -> ExceptT do
        -- Short circuits and adds Ada to any output utxo of the owner. This saves
        -- on fees but does not create a separate utxo. Do we want this behaviour?
        -- I expect if there are any output utxos to the user, they are either Ada
        -- only or non-Ada with minimum Ada value. Either way, we can just add the
        -- the value and it shouldn't incur extra fees.
        -- If we do require a new utxo, then we must add fees, under the assumption
        -- we have enough Ada in the input at this stage, otherwise we fail because
        -- we don't want to loop again over the addition of one output utxo.
        let
          changeIndex :: Maybe Int
          changeIndex =
            findIndex ((==) changeAddr <<< _.address <<< unwrap) txOutputs

        case changeIndex of
          Just idx -> pure do
            -- Add the Ada value to the first output utxo of the owner to not
            -- concur fees. This should be Ada only or non-Ada which has min Ada.
            newOutputs <-
              note
                ( ReturnAdaChangeError
                    "Couldn't modify utxo to return change."
                ) $
                modifyAt
                  idx
                  ( \(TransactionOutput o@{ amount }) -> TransactionOutput
                      o { amount = amount <> lovelaceValueOf returnAda }
                  )
                  txOutputs
            -- Fees unchanged because we aren't adding a new utxo.
            pure $
              wrap
                tx
                  { body = wrap txBody { outputs = newOutputs, fee = wrap fees }
                  }
          Nothing -> do
            -- Create a txBody with the extra output utxo then recalculate fees,
            -- then adjust as necessary if we have sufficient Ada in the input.
            let
              utxoCost :: BigInt
              utxoCost = getLovelace protocolParamUTxOCostPerWord

              changeMinUtxo :: BigInt
              changeMinUtxo = adaOnlyWords * utxoCost

              txBody' :: TxBody
              txBody' =
                wrap
                  txBody
                    { outputs =
                        wrap
                          { address: changeAddr
                          , amount: lovelaceValueOf returnAda
                          , dataHash: Nothing
                          }
                          `Array.cons` txBody.outputs
                    }

              tx' :: Transaction
              tx' = wrap tx { body = txBody' }

            fees'' <- lmap ReturnAdaChangeCalculateMinFee <$> calculateMinFee'
              tx'
            -- fees should increase.
            pure $ fees'' >>= \fees' -> do
              -- New return Ada amount should decrease:
              let returnAda' = returnAda + fees - fees'

              if returnAda' >= changeMinUtxo then do
                newOutputs <-
                  note
                    ( ReturnAdaChangeImpossibleError
                        "Couldn't modify head utxo to add Ada"
                        Impossible
                    )
                    $ modifyAt
                        0
                        ( \(TransactionOutput o) -> TransactionOutput
                            o { amount = lovelaceValueOf returnAda' }
                        )
                    $ _.outputs <<< unwrap
                    $ txBody'
                pure $
                  wrap
                    tx
                      { body = wrap txBody
                          { outputs = newOutputs, fee = wrap fees' }
                      }
              else
                Left $
                  ReturnAdaChangeError
                    "ReturnAda' does not cover min. utxo requirement for \
                    \single Ada-only output."

calculateMinUtxos :: Array TransactionOutput -> MinUtxos
calculateMinUtxos = map (\a -> a /\ calculateMinUtxo a)

-- https://cardano-ledger.readthedocs.io/en/latest/explanations/min-utxo-mary.html
-- https://github.com/input-output-hk/cardano-ledger/blob/master/doc/explanations/min-utxo-alonzo.rst
-- https://github.com/cardano-foundation/CIPs/tree/master/CIP-0028#rationale-for-parameter-choices
-- | Given an array of transaction outputs, return the paired amount of lovelaces
-- | required by each utxo.
calculateMinUtxo :: TransactionOutput -> BigInt
calculateMinUtxo txOut = unwrap lovelacePerUTxOWord * utxoEntrySize txOut
  where
  -- https://cardano-ledger.readthedocs.io/en/latest/explanations/min-utxo-mary.html
  -- https://github.com/input-output-hk/cardano-ledger/blob/master/doc/explanations/min-utxo-alonzo.rst
  utxoEntrySize :: TransactionOutput -> BigInt
  utxoEntrySize (TransactionOutput txOut') =
    let
      outputValue :: Value
      outputValue = txOut'.amount
    in
      if isAdaOnly outputValue then utxoEntrySizeWithoutVal + coinSize -- 29 in Alonzo
      else utxoEntrySizeWithoutVal
        + size outputValue
        + dataHashSize txOut'.dataHash

-- https://github.com/input-output-hk/cardano-ledger/blob/master/doc/explanations/min-utxo-alonzo.rst
-- | Calculates how many words are needed depending on whether the datum is
-- | hashed or not. 10 words for a hashed datum and 0 for no hash. The argument
-- | to the function is the datum hash found in `TransactionOutput`.
dataHashSize :: Maybe DataHash -> BigInt -- Should we add type safety?
dataHashSize Nothing = zero
dataHashSize (Just _) = fromInt 10

-- https://cardano-ledger.readthedocs.io/en/latest/explanations/min-utxo-mary.html
-- See "size"
size :: Value -> BigInt
size v = fromInt 6 + roundupBytesToWords b
  where
  b :: BigInt
  b = numTokenNames v * fromInt 12
    + sumTokenNameLengths v
    + numCurrencySymbols v * pidSize

  -- https://cardano-ledger.readthedocs.io/en/latest/explanations/min-utxo-mary.html
  -- Converts bytes to 8-byte long words, rounding up
  roundupBytesToWords :: BigInt -> BigInt
  roundupBytesToWords b' = quot (b' + (fromInt 7)) $ fromInt 8

-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs#L116
preBalanceTxBody
  :: MinUtxos
  -> BigInt
  -> Utxo
  -> Address
  -> TxBody
  -> Either BalanceTxError TxBody
preBalanceTxBody minUtxos fees utxos ownAddr txBody =
  -- -- Take a single Ada only utxo collateral
  -- addTxCollaterals utxos txBody
  --   >>= balanceTxIns utxos fees -- Add input fees for the Ada only collateral
  --   >>= balanceNonAdaOuts ownAddr utxos
  addLovelaces minUtxos txBody # pure
    >>= balanceTxIns utxos fees -- Adding more inputs if required
    >>= balanceNonAdaOuts ownAddr utxos

-- addTxCollaterals :: Utxo -> TxBody -> Either BalanceTxError TxBody
-- addTxCollaterals utxo txBody =
--   addTxCollaterals' utxo txBody # lmap AddTxCollateralsError

-- -- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs#L211
-- -- | Pick a collateral from the utxo map and add it to the unbalanced transaction
-- -- | (suboptimally we just pick a random utxo from the tx inputs). TO DO: upgrade
-- -- | to a better coin selection algorithm.
-- addTxCollaterals' :: Utxo -> TxBody -> Either AddTxCollateralsError TxBody
-- addTxCollaterals' utxos (TxBody txBody) = do
--   let
--     txIns :: Array TransactionInput
--     txIns = utxosToTransactionInput $ filterAdaOnly utxos
--   txIn :: TransactionInput <- findPubKeyTxIn txIns
--   pure $ wrap txBody { collateral = Just (Array.singleton txIn) }
--   where
--   filterAdaOnly :: Utxo -> Utxo
--   filterAdaOnly = Map.filter (isAdaOnly <<< getAmount)

--   -- Take head for collateral - can use better coin selection here.
--   findPubKeyTxIn
--     :: Array TransactionInput
--     -> Either AddTxCollateralsError TransactionInput
--   findPubKeyTxIn =
--     note CollateralUtxosUnavailable <<< Array.head

-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs
-- | Get `TransactionInput` such that it is associated to `PaymentCredentialKey`
-- | and not `PaymentCredentialScript`, i.e. we want wallets only
getPublicKeyTransactionInput
  :: TransactionInput /\ TransactionOutput
  -> Either GetPublicKeyTransactionInputError TransactionInput
getPublicKeyTransactionInput (txOutRef /\ txOut) =
  note CannotConvertScriptOutputToTxInput $ do
    paymentCred <- unwrap txOut # (_.address >>> addressPaymentCred)
    -- TEST ME: using StakeCredential to determine whether wallet or script
    paymentCred # withStakeCredential
      { onKeyHash: const $ pure txOutRef
      , onScriptHash: const Nothing
      }

balanceTxIns :: Utxo -> BigInt -> TxBody -> Either BalanceTxError TxBody
balanceTxIns utxos fees txbody =
  balanceTxIns' utxos fees txbody # lmap BalanceTxInsError'

-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs
-- Notice we aren't using protocol parameters for utxo cost per word.
balanceTxIns'
  :: Utxo
  -> BigInt
  -> TxBody
  -> Either BalanceTxInsError TxBody
balanceTxIns' utxos fees (TxBody txBody) = do
  let
    utxoCost :: BigInt
    utxoCost = getLovelace protocolParamUTxOCostPerWord

    changeMinUtxo :: BigInt
    changeMinUtxo = adaOnlyWords * utxoCost

    txOutputs :: Array TransactionOutput
    txOutputs = txBody.outputs

    mintVal :: Value
    mintVal = maybe mempty (mkValue (mkCoin zero) <<< unwrap) txBody.mint

  nonMintedValue <- note (BalanceTxInsCannotMinus $ CannotMinus $ wrap mintVal)
    $ Array.foldMap getAmount txOutputs `minus` mintVal

  -- Useful spies for debugging:
  -- let x = spy "nonMintedVal" nonMintedValue
  --     y = spy "feees" fees
  --     z = spy "changeMinUtxo" changeMinUtxo
  --     a = spy "txBody" txBody

  let
    minSpending :: Value
    minSpending = lovelaceValueOf (fees + changeMinUtxo) <> nonMintedValue

  -- a = spy "minSpending" minSpending

  txIns :: Array TransactionInput <-
    lmap
      ( \(CollectTxInsInsufficientTxInputs insufficientTxInputs) ->
          insufficientTxInputs
      )
      $ collectTxIns txBody.inputs utxos minSpending
  -- Original code uses Set append which is union. Array unions behave
  -- a little differently as it removes duplicates in the second argument.
  -- but all inputs should be unique anyway so I think this is fine.
  -- Note, this does not sort automatically unlike Data.Set
  pure $ wrap
    txBody
      { inputs = Array.union txIns txBody.inputs
      }

--https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs
-- | Getting the necessary input utxos to cover the fees for the transaction
collectTxIns
  :: Array TransactionInput
  -> Utxo
  -> Value
  -> Either CollectTxInsError (Array TransactionInput)
collectTxIns originalTxIns utxos value =
  if isSufficient updatedInputs then pure updatedInputs
  else
    Left $ CollectTxInsInsufficientTxInputs $
      InsufficientTxInputs (Expected value)
        (Actual $ txInsValue utxos updatedInputs)
  where
  updatedInputs :: Array TransactionInput
  updatedInputs =
    Foldable.foldl
      ( \newTxIns txIn ->
          if Array.elem txIn newTxIns || isSufficient newTxIns then newTxIns
          else Array.insert txIn newTxIns -- treat as a set.
      )
      originalTxIns
      $ utxosToTransactionInput utxos

  -- Useful spies for debugging:
  -- x = spy "collectTxIns:value" value
  -- y = spy "collectTxIns:txInsValueOG" (txInsValue utxos originalTxIns)
  -- z = spy "collectTxIns:txInsValueNEW" (txInsValue utxos updatedInputs)

  isSufficient :: Array TransactionInput -> Boolean
  isSufficient txIns' =
    not (Array.null txIns') && (txInsValue utxos txIns') `geq` value

txInsValue :: Utxo -> Array TransactionInput -> Value
txInsValue utxos =
  Array.foldMap getAmount <<< Array.mapMaybe (flip Map.lookup utxos)

utxosToTransactionInput :: Utxo -> Array TransactionInput
utxosToTransactionInput =
  Array.mapMaybe (hush <<< getPublicKeyTransactionInput) <<< Map.toUnfoldable

balanceNonAdaOuts
  :: Address
  -> Utxo
  -> TxBody
  -> Either BalanceTxError TxBody
balanceNonAdaOuts changeAddr utxos txBody =
  balanceNonAdaOuts' changeAddr utxos txBody # lmap BalanceNonAdaOutsError'

-- FIX ME: (payment credential) address for change substitute for pkh (Address)
-- https://github.com/mlabs-haskell/bot-plutus-interface/blob/master/src/BotPlutusInterface/PreBalance.hs#L225
-- | We need to balance non ada values as part of the prebalancer before returning
-- | excess Ada to the owner.
balanceNonAdaOuts'
  :: Address
  -> Utxo
  -> TxBody
  -> Either BalanceNonAdaOutsError TxBody
balanceNonAdaOuts' changeAddr utxos txBody'@(TxBody txBody) = do
  let -- FIX ME: Similar to Address issue, need pkh.
    -- payCredentials :: PaymentCredential
    -- payCredentials = addressPaymentCredentials changeAddr

    -- FIX ME: once both BaseAddresses are merged into one.
    -- pkh :: PubKeyHash
    -- pkh = addressPubKeyHash (unwrap changeAddr)."AddrType"

    txOutputs :: Array TransactionOutput
    txOutputs = txBody.outputs

    inputValue :: Value
    inputValue = getInputValue utxos txBody'

    outputValue :: Value
    outputValue = Array.foldMap getAmount txOutputs

    mintVal :: Value
    mintVal = maybe mempty (mkValue (mkCoin zero) <<< unwrap) txBody.mint

  nonMintedOutputValue <-
    note (BalanceNonAdaOutsCannotMinus $ CannotMinus $ wrap mintVal)
      $ outputValue `minus` mintVal

  let (nonMintedAdaOutputValue :: Value) = filterNonAda nonMintedOutputValue

  nonAdaChange <-
    note
      ( BalanceNonAdaOutsCannotMinus $ CannotMinus $ wrap
          nonMintedAdaOutputValue
      )
      $ filterNonAda inputValue `minus` nonMintedAdaOutputValue

  let
    -- Useful spies for debugging:
    -- a = spy "balanceNonAdaOuts'nonMintedOutputValue" nonMintedOutputValue
    -- b = spy "balanceNonAdaOuts'nonMintedAdaOutputValue" nonMintedAdaOutputValue
    -- c = spy "balanceNonAdaOuts'nonAdaChange" nonAdaChange
    -- d = spy "balanceNonAdaOuts'inputValue" inputValue

    outputs :: Array TransactionOutput
    outputs =
      Array.fromFoldable $
        case
          partition
            ((==) changeAddr <<< _.address <<< unwrap) --  <<< txOutPaymentCredentials)

            $ Array.toUnfoldable txOutputs
          of
          { no: txOuts, yes: Nil } ->
            TransactionOutput
              { address: changeAddr
              , amount: nonAdaChange
              , dataHash: Nothing
              } : txOuts
          { no: txOuts'
          , yes: TransactionOutput txOut@{ amount: v } : txOuts
          } ->
            TransactionOutput
              txOut { amount = v <> nonAdaChange } : txOuts <> txOuts'

  -- Original code uses "isNat" because there is a guard against zero, see
  -- isPos for more detail.
  if isPos nonAdaChange then pure $ wrap txBody { outputs = outputs }
  else if isZero nonAdaChange then pure $ wrap txBody
  else Left InputsCannotBalanceNonAdaTokens

getAmount :: TransactionOutput -> Value
getAmount = _.amount <<< unwrap

-- | Add min lovelaces to each tx output
addLovelaces :: MinUtxos -> TxBody -> TxBody
addLovelaces minLovelaces (TxBody txBody) =
  let
    lovelacesAdded :: Array TransactionOutput
    lovelacesAdded =
      map
        ( \txOut' ->
            let
              txOut = unwrap txOut'

              outValue :: Value
              outValue = txOut.amount

              lovelaces :: BigInt
              lovelaces = getLovelace $ valueToCoin outValue

              minUtxo :: BigInt
              minUtxo = fromMaybe zero $ Foldable.lookup txOut' minLovelaces
            in
              wrap
                txOut
                  { amount =
                      outValue
                        <> lovelaceValueOf (max zero $ minUtxo - lovelaces)
                  }
        )
        txBody.outputs
  in
    wrap txBody { outputs = lovelacesAdded }

getInputValue :: Utxo -> TxBody -> Value
getInputValue utxos (TxBody txBody) =
  Array.foldMap
    getAmount
    (Array.mapMaybe (flip Map.lookup utxos) <<< _.inputs $ txBody)
