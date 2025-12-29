-- Benchmark: Compute 5 statistics in a single pass using foldl'
-- Computes: sum, sum_of_squares, count, min, max
-- Then derives: mean, variance

import Data.List (foldl')
import Data.Int (Int64)

n :: Int
n = 100000000  -- 100M (sum_sq overflows but we're benchmarking speed)

main :: IO ()
main = do
    let (sum, sumSq, count, minV, maxV) =
            foldl' (\(s, sq, c, mn, mx) x ->
                ( s + x
                , sq + x * x
                , c + 1
                , min mn x
                , max mx x
                )) (0, 0, 0, maxBound, minBound) [1..n]

    let mean = fromIntegral sum / fromIntegral count :: Double
    let variance = (fromIntegral sumSq / fromIntegral count) - (mean * mean)

    putStrLn $ "Haskell foldl' stats:"
    putStrLn $ "  sum:      " ++ show sum
    putStrLn $ "  count:    " ++ show count
    putStrLn $ "  min:      " ++ show minV
    putStrLn $ "  max:      " ++ show maxV
    putStrLn $ "  mean:     " ++ show mean
    putStrLn $ "  variance: " ++ show variance
