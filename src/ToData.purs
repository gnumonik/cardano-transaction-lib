module ToData
  ( class ToData
  , class ToDataArgs
  , class ToDataWithSchema
  , class ToDataArgsRL
  , class ToDataArgsRLHelper
  , genericToData
  , toDataArgsRec
  , toDataArgsRec'
  , toData
  , toDataArgs
  , toDataWithSchema
  ) where

import Prelude
import Data.Array (cons, sortWith)
import Data.Array as Array
import Data.NonEmpty (NonEmpty)
import Data.BigInt (BigInt, fromInt)
import Data.BigInt as BigInt
import Data.Either (Either(Left, Right))
import Data.Foldable (class Foldable)
import Data.Generic.Rep as G
import Data.List (List)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Ratio (Ratio, denominator, numerator)
import Data.Symbol (class IsSymbol)
import Data.TextEncoder (encodeUtf8)
import Data.Tuple (Tuple(Tuple), fst, snd)
import Data.UInt (UInt)
import Helpers (uIntToBigInt)
import Prim.Row as Row
import Prim.TypeError (class Fail, Text)
import Record as Record
import Type.RowList as RL

import Plutus.Types.DataSchema (class HasPlutusSchema, class ValidPlutusSchema)
import TypeLevel.Nat (class KnownNat, natVal)
import TypeLevel.RowList.Unordered.Indexed
  ( class GetIndexWithLabel
  , class GetLabelIndex
  , class GetWithLabel
  )
import Type.Proxy (Proxy(Proxy))
import Types.ByteArray (ByteArray(ByteArray))
import Types.PlutusData (PlutusData(Constr, Integer, List, Bytes))

-- | Classes

class ToData :: Type -> Constraint
class ToData a where
  toData :: a -> PlutusData

{- | A class which converts a type to its PlutusData representation with the help of a
   generated or user-defined Plutus Data Schema (see TypeLevel.DataSchema.purs).
   We cannot express the constraint that the first type argument have an instance of
   @HasPlutusSchema@ with a superclass, but in practice every instance of this class will have an instance of
   that class as well.
-}
class ToDataWithSchema :: Type -> Type -> Constraint
class ToDataWithSchema t a where
  toDataWithSchema :: Proxy t -> a -> PlutusData

-- As explained in https://harry.garrood.me/blog/write-your-own-generics/ this
-- is just a neat pattern that flattens a skewed Product of Products
class ToDataArgs :: Type -> Symbol -> Type -> Constraint
class IsSymbol constr <= ToDataArgs t constr a where
  toDataArgs :: Proxy t -> Proxy constr -> a -> Array (PlutusData)

{- | A helper typeclass to implement `ToDataArgs` for records.
   Adapted from https://github.com/purescript/purescript-quickcheck/blob/v7.1.0/src/Test/QuickCheck/Arbitrary.purs#L247

   The Symbol argument represents the name of a constructor. To account for Sum types where multiple variants of the sum have
   records with the same name, we have to know the name of the constructor (at the type level). See TypeLevel.DataSchema for a
   more in depth explanation.
-}
class ToDataArgsRL
  :: forall (k :: Type)
   . Type
  -> Symbol
  -> RL.RowList k
  -> Row Type
  -> Constraint
class
  ToDataArgsRLHelper t constr list row <=
  ToDataArgsRL t constr list row
  | t constr list -> row where
  toDataArgsRec
    :: Proxy t
    -> Proxy constr
    -> Proxy list
    -> Record row
    -> Array PlutusData

instance ToDataArgsRLHelper t constr list row => ToDataArgsRL t constr list row where
  toDataArgsRec proxy constr list rec = map snd <<< sortWith fst $
    toDataArgsRec' proxy constr list rec

{- | A helper class used to implement ToDataArgsRL. This mainly exists for performance / ergonomic reasons;
   specifically, it allows us to only sort once (and not have to worry about maintaing the correct order as we go,
   which reduces the potential for errors)
-}
class ToDataArgsRLHelper
  :: forall (k :: Type)
   . Type
  -> Symbol
  -> RL.RowList k
  -> Row Type
  -> Constraint
class ToDataArgsRLHelper t constr list row | t constr list -> row where
  toDataArgsRec'
    :: Proxy t
    -> Proxy constr
    -> Proxy list
    -> Record row
    -> Array (Tuple Int PlutusData)

-- | ToDataWithIndex instances for Data.Generic.Rep

instance
  ( ToDataWithSchema t l
  , ToDataWithSchema t r
  ) =>
  ToDataWithSchema t (G.Sum l r) where
  toDataWithSchema p (G.Inl x) = toDataWithSchema p x
  toDataWithSchema p (G.Inr x) = toDataWithSchema p x

-- the following inline comments explain the "type level prolog" at work
instance
  ( -- 'constr' is the type variable which represents the type-level symbol corresponding to the name of a constructor. It must be known at compile time.
    IsSymbol constr
  -- Since this is an instance for constructors with arguments, we must ensure that the arguments can be converted to Plutus Data with the provided constr name
  , ToDataArgs t constr arg
  -- The type must have an associated Plutus Data Schema, else we can't derive the index (which we need to get ahold of with natVal in the body of the method)
  , HasPlutusSchema t schema
  -- The plutus schema must be valid, i.e., have no duplicate labels or indices at each level. Otherwise 'GetIndexWithLabel' might return the wrong result
  , ValidPlutusSchema schema list
  -- 'index' represents the type level Nat index of the field with the constr label.
  , GetIndexWithLabel constr list index
  -- If that index isn't known, we can't reflect it
  , KnownNat index
  ) =>
  ToDataWithSchema t (G.Constructor constr arg) where
  toDataWithSchema p (G.Constructor args) = Constr
    (fromInt <<< natVal $ (Proxy :: Proxy index))
    (toDataArgs p (Proxy :: Proxy constr) args)

-- | ToDataArgs instances for Data.Generic.Rep

instance IsSymbol constr => ToDataArgs a constr G.NoArguments where
  toDataArgs _ _ _ = []

instance
  ( ToDataArgs t constr (Record row)
  ) =>
  ToDataArgs t constr (G.Argument (Record row)) where
  toDataArgs proxy constr (G.Argument r) = toDataArgs proxy constr r
else instance (ToData a, IsSymbol constr) => ToDataArgs x constr (G.Argument a) where
  toDataArgs _ _ (G.Argument x) = [ toData x ]

instance
  ( IsSymbol constr
  , ToDataArgsRL t constr list row
  , RL.RowToList row list
  ) =>
  ToDataArgs t constr (Record row) where
  toDataArgs proxy constr rec = toDataArgsRec proxy constr (Proxy :: Proxy list)
    rec

instance
  ( ToDataArgs x constr a
  , ToDataArgs x constr b
  ) =>
  ToDataArgs x constr (G.Product a b) where
  toDataArgs proxy constr (G.Product x y) = toDataArgs proxy constr x <>
    toDataArgs proxy constr y

-- | ToDataArgsRL instances

instance ToDataArgsRLHelper t symbol RL.Nil () where
  toDataArgsRec' _ _ _ _ = []
else instance
  ( -- The element of the Row we are inspecting must be convertible to Plutus Data
    ToData a
  -- The tail of the RowList we are inspecting must be convertible to Plutus Data (with the current constructor name)
  , ToDataArgsRLHelper t constr listRest rowRest
  -- Row.Lacks and Row.Cons are just the constraints required to use Record.Get
  , Row.Lacks label rowRest
  , Row.Cons label a rowRest rowFull
  , RL.RowToList rowFull (RL.Cons label a listRest)
  -- 'label' is a type variable which represents the Symbol label of a *record entry*
  , IsSymbol label
  -- As in the rest of this module, 'constr' stands for the name of the constructor which has a Record argument that we are inspecting
  , IsSymbol constr
  -- The type 't' is the "parent type" which has a constructor ('constr') that takes a Record argument
  , HasPlutusSchema t schema
  -- The schema must be valid (see above), and if it is we get the corresponding RList ('rList')
  , ValidPlutusSchema schema rList
  -- The RList corresponding to the schema must have a Record argument at the given constructor
  , GetWithLabel constr rList rec
  -- That record at the given constructor must have a field at the given label, and that field has a Nat index
  , GetLabelIndex label rec n
  -- we have to be able to reflect the nat index of the record entry located at 'label'
  , KnownNat n
  ) =>
  ToDataArgsRLHelper t constr (RL.Cons label a listRest) rowFull where
  toDataArgsRec' _ constr _ x =
    let
      keyProxy = (Proxy :: Proxy label)

      ix = natVal (Proxy :: Proxy n)

      field :: a
      field = Record.get keyProxy x
    in
      Tuple ix (toData field) `cons` toDataArgsRec' (Proxy :: Proxy t) constr
        (Proxy :: Proxy listRest)
        (Record.delete keyProxy x)

genericToData
  :: forall (t :: Type) (rep :: Type)
   . G.Generic t rep
  => ToDataWithSchema t rep
  => t
  -> PlutusData
genericToData = toDataWithSchema (Proxy :: Proxy t) <<< G.from

-- | Base ToData instances

instance ToData Void where
  toData = absurd

instance ToData Unit where
  toData _ = Constr zero []

-- NOTE: For the sake of compatibility the following toDatas have to match
-- https://github.com/input-output-hk/plutus/blob/1f31e640e8a258185db01fa899da63f9018c0e85/plutus-tx/src/PlutusTx/IsData/Instances.hs
instance ToData Boolean where
  toData false = Constr zero []
  toData true = Constr one []

instance ToData a => ToData (Maybe a) where
  toData (Just x) = Constr zero [ toData x ] -- Just is zero-indexed by Plutus
  toData Nothing = Constr one []

instance (ToData a, ToData b) => ToData (Either a b) where
  toData (Left e) = Constr zero [ toData e ]
  toData (Right x) = Constr one [ toData x ]

instance Fail (Text "Int is not supported, use BigInt instead") => ToData Int where
  toData = toData <<< BigInt.fromInt

instance ToData BigInt where
  toData = Integer

instance ToData UInt where
  toData = toData <<< uIntToBigInt

instance ToData a => ToData (Array a) where
  toData = List <<< map toData

instance (Foldable f, ToData a) => ToData (NonEmpty f a) where
  toData = foldableToPlutusData

instance ToData a => ToData (List a) where
  toData = foldableToPlutusData

instance (ToData a, ToData b) => ToData (Tuple a b) where
  toData (Tuple a b) = Constr zero [ toData a, toData b ]

-- Note that nothing prevents the denominator from being zero, we could provide
-- safety here:
instance ToData a => ToData (Ratio a) where
  toData ratio = List [ toData (numerator ratio), toData (denominator ratio) ]

instance ToData ByteArray where
  toData = Bytes

instance ToData String where
  toData = toData <<< ByteArray <<< encodeUtf8

instance ToData PlutusData where
  toData = identity

foldableToPlutusData
  :: forall (a :: Type) (t :: Type -> Type)
   . Foldable t
  => ToData a
  => t a
  -> PlutusData
foldableToPlutusData = Array.fromFoldable >>> map toData >>> List
