{-
Copyright 2016 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module SlamData.Workspace.Card.Chart.Aggregation where

import SlamData.Prelude

import Data.Argonaut (fromString, class EncodeJson, class DecodeJson, decodeJson)
import Data.Foldable (sum, product)
import Data.List as L

import SlamData.Form.Select (class OptionVal, Select(..))

import Test.StrongCheck as SC
import Test.StrongCheck.Gen as Gen

data Aggregation
  = Maximum
  | Minimum
  | Average
  | Sum
  | Product

allAggregations ∷ Array Aggregation
allAggregations =
  [ Maximum
  , Minimum
  , Average
  , Sum
  , Product
  ]

defaultAggregation ∷ Aggregation
defaultAggregation = Sum

printAggregation ∷ Aggregation → String
printAggregation Maximum = "Maximum"
printAggregation Minimum = "Minimum"
printAggregation Average = "Average"
printAggregation Sum = "Sum"
printAggregation Product = "Product"

parseAggregation ∷ String → Either String Aggregation
parseAggregation "Maximum" = pure Maximum
parseAggregation "Minimum" = pure Minimum
parseAggregation "Average" = pure Average
parseAggregation "Sum" = pure Sum
parseAggregation "Product" = pure Product
parseAggregation _ = Left "Incorrect aggregation string"

runAggregation
  ∷ ∀  a f
  . (Ord a, ModuloSemiring a, Foldable f)
  ⇒ Aggregation
  → f a
  → a
runAggregation Maximum nums = foldl (\b a → if b > a then b else a) zero nums
runAggregation Minimum nums = foldl (\b a → if b > a then a else b) zero nums
runAggregation Average nums =
  normalize
  $ foldl (\acc a → bimap (add one) (add a) acc)  (Tuple zero zero) nums
  where
  normalize (Tuple count sum) = sum / count
runAggregation Sum nums = sum nums
runAggregation Product nums = product nums

aggregationSelect ∷ Select Aggregation
aggregationSelect =
  Select
     { value: Just Sum
     , options: allAggregations
     }


derive instance genericAggregation ∷ Generic Aggregation
derive instance eqAggregation ∷ Eq Aggregation
derive instance ordAggregation ∷ Ord Aggregation

instance encodeJsonAggregation ∷ EncodeJson Aggregation where
  encodeJson = fromString <<< printAggregation
instance decodeJsonAggregation ∷ DecodeJson Aggregation where
  decodeJson = decodeJson >=> parseAggregation

instance optionValAggregation ∷ OptionVal Aggregation where
  stringVal = printAggregation

instance arbitraryAggregation ∷ SC.Arbitrary Aggregation where
  arbitrary = Gen.elements defaultAggregation $ L.toList allAggregations
