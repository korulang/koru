{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE Strict #-}
-- Benchmark: Using Int64 explicitly to match Koru/Zig

import Data.List (foldl')
import Data.Int (Int64)

n :: Int64
n = 100000000

data Stats = Stats !Int64 !Int64 !Int64 !Int64 !Int64
  deriving Show

main :: IO ()
main = do
    let Stats !sum !sumSq !count !minV !maxV =
            foldl' (\(Stats !s !sq !c !mn !mx) !x ->
                Stats (s + x) (sq + x * x) (c + 1) (min mn x) (max mx x)
                ) (Stats 0 0 0 maxBound minBound) [1..n]

    let mean = fromIntegral sum / fromIntegral count :: Double
    let variance = (fromIntegral sumSq / fromIntegral count) - (mean * mean)

    putStrLn $ "Haskell Int64 stats:"
    putStrLn $ "  sum:      " ++ show sum
    putStrLn $ "  count:    " ++ show count
    putStrLn $ "  min:      " ++ show minV
    putStrLn $ "  max:      " ++ show maxV
