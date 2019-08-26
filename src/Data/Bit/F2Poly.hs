{-# LANGUAGE CPP                        #-}

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}

#ifndef BITVEC_THREADSAFE
module Data.Bit.F2Poly
#else
module Data.Bit.F2PolyTS
#endif
  ( F2Poly
  , unF2Poly
  , toF2Poly
  ) where

import Control.DeepSeq
import Control.Monad
import Control.Monad.ST
#ifndef BITVEC_THREADSAFE
import Data.Bit.Immutable
import Data.Bit.Internal
#else
import Data.Bit.ImmutableTS
import Data.Bit.InternalTS
#endif
import Data.Bit.Utils
import Data.Bits
import Data.Coerce
import Data.List hiding (dropWhileEnd)
import Data.Typeable
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU
import GHC.Generics

newtype F2Poly = F2Poly { unF2Poly :: U.Vector Bit }
  deriving (Eq, Ord, Show, Typeable, Generic, NFData)

toF2Poly :: U.Vector Bit -> F2Poly
toF2Poly = F2Poly . dropWhileEnd

instance Num F2Poly where
  (+) = coerce ((dropWhileEnd .) . xorBits)
  (-) = coerce ((dropWhileEnd .) . xorBits)
  negate = id
  abs    = id
  signum = const (F2Poly (U.singleton (Bit True)))
  fromInteger n
    | odd n     = F2Poly (U.singleton (Bit True))
    | otherwise = F2Poly U.empty
  (*) = coerce ((dropWhileEnd .) . karatsuba)

xorBits
  :: U.Vector Bit
  -> U.Vector Bit
  -> U.Vector Bit
xorBits xs ys = runST $ do
  let lx = U.length xs
      ly = U.length ys
      (shorterLen, longerLen, longer) = if lx >= ly then (ly, lx, xs) else (lx, ly, ys)
  zs <- MU.new longerLen
  forM_ [0, wordSize .. shorterLen - 1] $ \i ->
    writeWord zs i (indexWord xs i `xor` indexWord ys i)
  U.unsafeCopy (MU.drop shorterLen zs) (U.drop shorterLen longer)
  U.unsafeFreeze zs

karatsubaThreshold :: Int
karatsubaThreshold = 4096

karatsuba :: U.Vector Bit -> U.Vector Bit -> U.Vector Bit
karatsuba xs ys
  | xs == ys = sqrBits xs
  | lenXs <= karatsubaThreshold || lenYs <= karatsubaThreshold
  = mulBits xs ys
  | otherwise = runST $ do
    zs <- MU.unsafeNew lenZs
    forM_ [0, wordSize .. lenZs - 1] $ \k -> do
      let z0  = indexWord0 zs0   k
          z11 = indexWord0 zs11 (k - m)
          z10 = indexWord0 zs0  (k - m)
          z12 = indexWord0 zs2  (k - m)
          z2  = indexWord0 zs2  (k - 2 * m)
      writeWord zs k (z0 `xor` z11 `xor` z10 `xor` z12 `xor` z2)
    U.unsafeFreeze zs
  where
    lenXs = U.length xs
    lenYs = U.length ys
    lenZs = lenXs + lenYs - 1

    m'    = ((lenXs `min` lenYs) + 1) `quot` 2
    m     = if karatsubaThreshold < wordSize then m' else m' - modWordSize m'

    xs0  = U.slice 0 m xs
    xs1  = U.slice m (lenXs - m) xs
    ys0  = U.slice 0 m ys
    ys1  = U.slice m (lenYs - m) ys

    xs01 = xorBits xs0 xs1
    ys01 = xorBits ys0 ys1
    zs0  = karatsuba xs0 ys0
    zs2  = karatsuba xs1 ys1
    zs11 = karatsuba xs01 ys01

indexWord0 :: U.Vector Bit -> Int -> Word
indexWord0 bv i
  | i <= - wordSize         = 0
  | lenI <= 0               = 0
  | i < 0, lenI >= wordSize = word0
  | i < 0                   = word0 .&. loMask lenI
  | lenI >= wordSize        = word
  | otherwise               = word .&. loMask lenI
  where
    lenI  = U.length bv - i
    word  = indexWord bv i
    word0 = indexWord bv 0 `unsafeShiftL` (- i)

mulBits :: U.Vector Bit -> U.Vector Bit -> U.Vector Bit
mulBits xs ys
  | lenXs == 0 || lenYs == 0 = U.empty
  | otherwise = U.generate lenZs go
  where
    lenXs = U.length xs
    lenYs = U.length ys
    lenZs = lenXs + lenYs - 1
    rys   = reverseBits ys

    go :: Int -> Bit
    go k = zipAndCountParityBits (U.drop xFrom xs) (U.drop yFrom rys)
      where
        xFrom = max (k - (lenYs - 1)) 0
        yFrom = max 0 (lenYs - 1 - k)

zipAndCountParityBits :: U.Vector Bit -> U.Vector Bit -> Bit
zipAndCountParityBits xs ys
  | nMod == 0 = fromIntegral $ popCnt
  | otherwise = fromIntegral $ popCnt `xor` lastPopCnt
  where
    n = min (U.length xs) (U.length ys)
    nMod = modWordSize n
    ff i = indexWord xs i .&. indexWord ys i
    popCnt = foldl' (\acc i -> acc `xor` popCount (ff i)) 0 [0, wordSize .. n - nMod - 1]
    lastPopCnt = popCount (ff (n - nMod) .&. loMask nMod)

sqrBits :: U.Vector Bit -> U.Vector Bit
sqrBits xs = runST $ do
    let lenXs = U.length xs
    zs <- MU.new (lenXs `shiftL` 1)
    forM_ [0, wordSize .. lenXs - 1] $ \i -> do
      let (z0, z1) = sparseBits (indexWord xs i)
      writeWord zs (i `shiftL` 1) z0
      writeWord zs (i `shiftL` 1 + wordSize) z1
    U.unsafeFreeze zs

dropWhileEnd
  :: U.Vector Bit
  -> U.Vector Bit
dropWhileEnd xs = U.unsafeSlice 0 (go (U.length xs)) xs
  where
    go 0 = 0
    go n = if unBit (U.unsafeIndex xs (n - 1)) then n else go (n - 1)
