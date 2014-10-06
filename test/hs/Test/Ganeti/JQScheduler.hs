{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{-| Unittests for the job scheduler.

-}

{-

Copyright (C) 2014 Google Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-}

module Test.Ganeti.JQScheduler (testJQScheduler) where

import Control.Applicative
import Control.Lens ((&), (.~), _2)
import qualified Data.Map as Map
import Data.Set (difference)
import qualified Data.Set as Set
import Data.Traversable (traverse)
import Test.HUnit
import Test.QuickCheck

import Test.Ganeti.JQueue.Objects (genQueuedOpCode, genJobId, justNoTs)
import Test.Ganeti.SlotMap (genTestKey, overfullKeys)
import Test.Ganeti.TestCommon
import Test.Ganeti.TestHelper
import Test.Ganeti.Types ()

import Ganeti.JQScheduler.ReasonRateLimiting
import Ganeti.JQScheduler.Types
import Ganeti.JQueue.Lens
import Ganeti.JQueue.Objects
import Ganeti.OpCodes.Lens
import Ganeti.SlotMap

{-# ANN module "HLint: ignore Use camelCase" #-}


genRateLimitReason :: Gen String
genRateLimitReason = do
  Slot{ slotLimit = n } <- arbitrary
  l <- genTestKey
  return $ "rate-limit:" ++ show n ++ ":" ++ l


instance Arbitrary QueuedJob where
  arbitrary = do
    -- For our scheduler testing purposes here, we only care about
    -- opcodes, job ID and reason rate limits.
    jid <- genJobId

    ops <- resize 5 . listOf1 $ do
      o <- genQueuedOpCode
      -- Put some rate limits into the OpCode.
      limitString <- genRateLimitReason
      return $
        o & qoInputL . validOpCodeL . metaParamsL . opReasonL . traverse . _2
          .~ limitString

    return $ QueuedJob jid ops justNoTs justNoTs justNoTs Nothing Nothing


instance Arbitrary JobWithStat where
  arbitrary = nullJobWithStat <$> arbitrary
  shrink job = [ job { jJob = x } | x <- shrink (jJob job) ]


instance Arbitrary Queue where
  arbitrary = do
    let jobListGen = listOf arbitrary
    Queue <$> jobListGen <*> jobListGen <*> jobListGen
  shrink q =
    [ q { qEnqueued = x }    | x <- shrink (qEnqueued q) ] ++
    [ q { qRunning = x }     | x <- shrink (qRunning q) ] ++
    [ q { qManipulated = x } | x <- shrink (qManipulated q) ]


-- * Test cases

-- | Tests rate limit reason trail parsing.
case_parseReasonRateLimit :: Assertion
case_parseReasonRateLimit = do

  assertBool "default case" $
    let a = parseReasonRateLimit "rate-limit:20:my label"
        b = parseReasonRateLimit "rate-limit:21:my label"
    in and
         [ a == Just ("20:my label", 20)
         , b == Just ("21:my label", 21)
         ]

  assertEqual "be picky about whitespace"
    Nothing
    (parseReasonRateLimit " rate-limit:20:my label")


-- | Tests that "rateLimit:n:..." and "rateLimit:m:..." become different
-- rate limiting buckets.
prop_slotMapFromJob_conflicting_buckets :: Property
prop_slotMapFromJob_conflicting_buckets = do

  let sameBucketReasonStringGen :: Gen (String, String)
      sameBucketReasonStringGen = do
        (Positive (n :: Int), Positive (m :: Int)) <- arbitrary
        l <- genPrintableAsciiString
        return ( "rate-limit:" ++ show n ++ ":" ++ l
               , "rate-limit:" ++ show m ++ ":" ++ l )

  forAll sameBucketReasonStringGen $ \(s1, s2) ->
    (s1 /= s2) ==> do
      (lab1, lim1) <- parseReasonRateLimit s1
      (lab2, _   ) <- parseReasonRateLimit s2
      let sm = Map.fromList [(lab1, Slot 1 lim1)]
          cm = Map.fromList [(lab2, 1)]
       in (sm `occupySlots` cm) ==? Map.fromList [ (lab1, Slot 1 lim1)
                                                 , (lab2, Slot 1 0)   ]


-- | Tests the specified properties of `reasonRateLimit`, as defined in
-- `doc/design-optables.rst`.
prop_reasonRateLimit :: Property
prop_reasonRateLimit =
  forAllShrink arbitrary shrink $ \q ->

    let slotMapFromJobWithStat = slotMapFromJobs . map jJob

        toRun = reasonRateLimit q (qEnqueued q)

        oldSlots         = slotMapFromJobWithStat (qRunning q)
        newSlots         = slotMapFromJobWithStat (qRunning q ++ toRun)
        -- What would happen without rate limiting.
        newSlotsNoLimits = slotMapFromJobWithStat (qRunning q ++ qEnqueued q)

    in -- Ensure it's unlikely that jobs are all in different buckets.
       cover
         (any ((> 1) . slotOccupied) . Map.elems $ newSlotsNoLimits)
         50
         "some jobs have the same rate-limit bucket"

       -- Ensure it's likely that rate limiting has any effect.
       . cover
           (overfullKeys newSlotsNoLimits
              `difference` overfullKeys oldSlots /= Set.empty)
           50
           "queued jobs cannot be started because of rate limiting"

       $ conjoin
           [ printTestCase "order must be preserved" $
               toRun ==? filter (`elem` toRun) (qEnqueued q)

           -- This is the key property:
           , printTestCase "no job may exceed its bucket limits, except from\
                            \ jobs that were already running with exceeded\
                            \ limits; those must not increase" $
               conjoin
                 [ if occup <= limit
                     -- Within limits, all fine.
                     then passTest
                     -- Bucket exceeds limits - it must have exceeded them
                     -- in the initial running list already, with the same
                     -- slot count.
                     else Map.lookup k oldSlots ==? Just slot
                 | (k, slot@(Slot occup limit)) <- Map.toList newSlots ]
           ]

testSuite "JQScheduler"
            [ 'case_parseReasonRateLimit
            , 'prop_slotMapFromJob_conflicting_buckets
            , 'prop_reasonRateLimit
            ]