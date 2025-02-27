module Serialization.WitnessSet where

import Prelude

import Data.Newtype (unwrap)
import Data.Array as Array
import Data.Maybe (Maybe, maybe)
import Data.Traversable (for_, traverse, traverse_)
import Data.Tuple.Nested ((/\))
import Effect (Effect)
import Effect.Exception (throw)
import FfiHelpers
  ( ContainerHelper
  , MaybeFfiHelper
  , containerHelper
  , maybeFfiHelper
  )
import Serialization.BigNum (bigNumFromBigInt)
import Serialization.NativeScript (convertNativeScripts)
import Serialization.PlutusData (convertPlutusData)
import Serialization.Types
  ( BigNum
  , BootstrapWitness
  , Ed25519Signature
  , ExUnits
  , NativeScripts
  , PlutusScript
  , PlutusScripts
  , PublicKey
  , Redeemer
  , Redeemers
  , RedeemerTag
  , TransactionWitnessSet
  , Vkey
  , Vkeywitness
  , Vkeywitnesses
  )
import Serialization.Types (PlutusData) as PDS
import Types.Aliases (Bech32String)
import Types.ByteArray (ByteArray)
import Types.PlutusData (PlutusData) as PD
import Types.RedeemerTag as Tag
import Types.Scripts (PlutusScript(PlutusScript)) as S
import Types.Transaction
  ( BootstrapWitness
  , Ed25519Signature(Ed25519Signature)
  , ExUnits
  , PublicKey(PublicKey)
  , Redeemer(Redeemer)
  , TransactionWitnessSet(TransactionWitnessSet)
  , Vkey(Vkey)
  , Vkeywitness(Vkeywitness)
  ) as T

setPlutusData :: PDS.PlutusData -> TransactionWitnessSet -> Effect Unit
setPlutusData pd ws = setWitness _wsSetPlutusData ws pd

setRedeemer :: Redeemer -> TransactionWitnessSet -> Effect Unit
setRedeemer r ws = setWitness _wsSetRedeemers ws r

setPlutusScript :: PlutusScript -> TransactionWitnessSet -> Effect Unit
setPlutusScript ps ws = setWitness _wsSetPlutusScripts ws ps

setWitness
  :: forall (a :: Type)
   . (ContainerHelper -> TransactionWitnessSet -> Array a -> Effect Unit)
  -> TransactionWitnessSet
  -> a
  -> Effect Unit
setWitness f ws = f containerHelper ws <<< Array.singleton

convertWitnessSet :: T.TransactionWitnessSet -> Effect TransactionWitnessSet
convertWitnessSet (T.TransactionWitnessSet tws) = do
  ws <- newTransactionWitnessSet
  for_ tws.vkeys
    (convertVkeywitnesses >=> transactionWitnessSetSetVkeys ws)
  for_ tws.nativeScripts $
    maybe (throw "Failed to convert NativeScripts")
      (transactionWitnessSetSetNativeScripts ws) <<< convertNativeScripts
  for_ tws.bootstraps
    (traverse convertBootstrap >=> _wsSetBootstraps containerHelper ws)
  for_ tws.plutusScripts \ps -> do
    scripts <- newPlutusScripts
    for_ ps (convertPlutusScript >=> addPlutusScript scripts)
    txWitnessSetSetPlutusScripts ws scripts
  for_ tws.plutusData
    (traverse convertPlutusDataEffect >=> _wsSetPlutusData containerHelper ws)
  for_ tws.redeemers
    (traverse convertRedeemer >=> _wsSetRedeemers containerHelper ws)
  pure ws

convertRedeemers :: Array T.Redeemer -> Effect Redeemers
convertRedeemers redeemers = do
  _mkRedeemers containerHelper <$> traverse convertRedeemer redeemers

convertRedeemer :: T.Redeemer -> Effect Redeemer
convertRedeemer (T.Redeemer { tag, index, "data": data_, exUnits }) = do
  tag' <- convertRedeemerTag tag
  index' <- maybe (throw "Failed to convert redeemer index") pure $
    bigNumFromBigInt index
  data' <- convertPlutusDataEffect data_
  exUnits' <- convertExUnits exUnits
  newRedeemer tag' index' data' exUnits'

convertPlutusDataEffect :: PD.PlutusData -> Effect PDS.PlutusData
convertPlutusDataEffect pd = maybe (throw "Failed to convert PlutusData") pure $
  convertPlutusData
    pd

convertRedeemerTag :: Tag.RedeemerTag -> Effect RedeemerTag
convertRedeemerTag = _newRedeemerTag <<< case _ of
  Tag.Spend -> "spend"
  Tag.Mint -> "mint"
  Tag.Cert -> "cert"
  Tag.Reward -> "reward"

convertExUnits :: T.ExUnits -> Effect ExUnits
convertExUnits { mem, steps } =
  maybe (throw "Failed to construct ExUnits") pure do
    mem' <- bigNumFromBigInt mem
    steps' <- bigNumFromBigInt steps
    pure $ newExUnits mem' steps'

convertBootstrap :: T.BootstrapWitness -> Effect BootstrapWitness
convertBootstrap { vkey, signature, chainCode, attributes } = do
  vkey' <- convertVkey vkey
  signature' <- convertEd25519Signature signature
  newBootstrapWitness vkey' signature' chainCode attributes

-- | NOTE: Does JS new object allocation without the Effect monad.
convertPlutusScriptMaybe :: S.PlutusScript -> Maybe PlutusScript
convertPlutusScriptMaybe = newPlutusScriptMaybe <<< unwrap

convertPlutusScript :: S.PlutusScript -> Effect PlutusScript
convertPlutusScript (S.PlutusScript bytes) = do
  newPlutusScript bytes

convertVkeywitnesses :: Array T.Vkeywitness -> Effect Vkeywitnesses
convertVkeywitnesses arr = do
  witnesses <- newVkeywitnesses
  traverse_ (convertVkeywitness >=> addVkeywitness witnesses) arr
  pure witnesses

convertVkeywitness :: T.Vkeywitness -> Effect Vkeywitness
convertVkeywitness (T.Vkeywitness (vkey /\ signature)) = do
  vkey' <- convertVkey vkey
  signature' <- convertEd25519Signature signature
  newVkeywitness vkey' signature'

convertEd25519Signature :: T.Ed25519Signature -> Effect Ed25519Signature
convertEd25519Signature (T.Ed25519Signature bech32) =
  newEd25519Signature bech32

convertVkey :: T.Vkey -> Effect Vkey
convertVkey (T.Vkey (T.PublicKey pk)) =
  newPublicKey pk >>= newVkeyFromPublicKey

foreign import newTransactionWitnessSet :: Effect TransactionWitnessSet
foreign import newEd25519Signature :: Bech32String -> Effect Ed25519Signature
foreign import newPublicKey :: Bech32String -> Effect PublicKey
foreign import newVkeyFromPublicKey :: PublicKey -> Effect Vkey
foreign import newVkeywitnesses :: Effect Vkeywitnesses
foreign import newVkeywitness :: Vkey -> Ed25519Signature -> Effect Vkeywitness
foreign import addVkeywitness :: Vkeywitnesses -> Vkeywitness -> Effect Unit
foreign import newPlutusScript :: ByteArray -> Effect PlutusScript
foreign import _newPlutusScriptMaybe
  :: MaybeFfiHelper -> ByteArray -> Maybe PlutusScript

newPlutusScriptMaybe :: ByteArray -> Maybe PlutusScript
newPlutusScriptMaybe = _newPlutusScriptMaybe maybeFfiHelper

foreign import newPlutusScripts :: Effect PlutusScripts
foreign import addPlutusScript :: PlutusScripts -> PlutusScript -> Effect Unit
foreign import transactionWitnessSetSetVkeys
  :: TransactionWitnessSet -> Vkeywitnesses -> Effect Unit

foreign import txWitnessSetSetPlutusScripts
  :: TransactionWitnessSet -> PlutusScripts -> Effect Unit

foreign import transactionWitnessSetSetNativeScripts
  :: TransactionWitnessSet -> NativeScripts -> Effect Unit

foreign import _wsSetBootstraps
  :: ContainerHelper
  -> TransactionWitnessSet
  -> Array BootstrapWitness
  -> Effect Unit

foreign import newBootstrapWitness
  :: Vkey
  -> Ed25519Signature
  -> ByteArray
  -> ByteArray
  -> Effect BootstrapWitness

foreign import _wsSetPlutusData
  :: ContainerHelper
  -> TransactionWitnessSet
  -> Array PDS.PlutusData
  -> Effect Unit

foreign import newRedeemer
  :: RedeemerTag -> BigNum -> PDS.PlutusData -> ExUnits -> Effect Redeemer

foreign import _newRedeemerTag :: String -> Effect RedeemerTag
foreign import newExUnits :: BigNum -> BigNum -> ExUnits
foreign import _wsSetRedeemers
  :: ContainerHelper -> TransactionWitnessSet -> Array Redeemer -> Effect Unit

foreign import _mkRedeemers :: ContainerHelper -> Array Redeemer -> Redeemers
foreign import _wsSetPlutusScripts
  :: ContainerHelper
  -> TransactionWitnessSet
  -> Array PlutusScript
  -> Effect Unit
