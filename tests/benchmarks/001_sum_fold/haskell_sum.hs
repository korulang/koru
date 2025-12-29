-- Benchmark: Sum of 1 to N using foldl'

import Data.List (foldl')

n :: Int
n = 100000000  -- 100M

main :: IO ()
main = do
    let result = foldl' (+) 0 [1..n]
    putStrLn $ "Haskell foldl' sum: " ++ show result
