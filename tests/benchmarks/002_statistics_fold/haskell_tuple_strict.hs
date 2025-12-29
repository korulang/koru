{-# LANGUAGE BangPatterns #-}
-- Tuple with explicit bang patterns to force all fields

import Data.List (foldl')

n :: Int
n = 100000000

step :: (Int,Int,Int,Int,Int) -> Int -> (Int,Int,Int,Int,Int)
step (!s,!sq,!c,!mn,!mx) !x =
  let !s'  = s  + x
      !sq' = sq + x*x
      !c'  = c  + 1
      !mn' = min mn x
      !mx' = max mx x
  in (s',sq',c',mn',mx')

main :: IO ()
main = do
    let (!sum, !sumSq, !count, !minV, !maxV) = foldl' step (0,0,0,maxBound,minBound) [1..n]

    putStrLn $ "Haskell tuple+bangs stats:"
    putStrLn $ "  sum:      " ++ show sum
    putStrLn $ "  count:    " ++ show count
    putStrLn $ "  min:      " ++ show minV
    putStrLn $ "  max:      " ++ show maxV
