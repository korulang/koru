{-# LANGUAGE BangPatterns #-}
-- N-body benchmark - Haskell (GHC) reference
-- Compiled with: ghc -O2 -o nbody nbody.hs

import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.IO (IOUArray, newArray_)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import Text.Printf (hPrintf)

solarMass :: Double
solarMass = 4 * pi * pi

daysPerYear :: Double
daysPerYear = 365.24

dt :: Double
dt = 0.01

type Vec = IOUArray Int Double

data Bodies = Bodies !Vec !Vec !Vec !Vec !Vec !Vec !Vec

set :: Vec -> Int -> Double -> IO ()
set = unsafeWrite
{-# INLINE set #-}

get :: Vec -> Int -> IO Double
get = unsafeRead
{-# INLINE get #-}

initBodies :: IO Bodies
initBodies = do
  x  <- newArray_ (0,4) :: IO Vec
  y  <- newArray_ (0,4) :: IO Vec
  z  <- newArray_ (0,4) :: IO Vec
  vx <- newArray_ (0,4) :: IO Vec
  vy <- newArray_ (0,4) :: IO Vec
  vz <- newArray_ (0,4) :: IO Vec
  m  <- newArray_ (0,4) :: IO Vec
  -- Sun
  set x 0 0; set y 0 0; set z 0 0
  set vx 0 0; set vy 0 0; set vz 0 0
  set m 0 solarMass
  -- Jupiter
  set x 1 4.84143144246472090e+00
  set y 1 (-1.16032004402742839e+00)
  set z 1 (-1.03622044471123109e-01)
  set vx 1 (1.66007664274403694e-03 * daysPerYear)
  set vy 1 (7.69901118419740425e-03 * daysPerYear)
  set vz 1 ((-6.90460016972063023e-05) * daysPerYear)
  set m 1 (9.54791938424326609e-04 * solarMass)
  -- Saturn
  set x 2 8.34336671824457987e+00
  set y 2 4.12479856412430479e+00
  set z 2 (-4.03523417114321381e-01)
  set vx 2 ((-2.76742510726862411e-03) * daysPerYear)
  set vy 2 (4.99852801234917238e-03 * daysPerYear)
  set vz 2 (2.30417297573763929e-05 * daysPerYear)
  set m 2 (2.85885980666130812e-04 * solarMass)
  -- Uranus
  set x 3 1.28943695621391310e+01
  set y 3 (-1.51111514016986312e+01)
  set z 3 (-2.23307578892655734e-01)
  set vx 3 (2.96460137564761618e-03 * daysPerYear)
  set vy 3 (2.37847173959480950e-03 * daysPerYear)
  set vz 3 ((-2.96589568540237556e-05) * daysPerYear)
  set m 3 (4.36624404335156298e-05 * solarMass)
  -- Neptune
  set x 4 1.53796971148509165e+01
  set y 4 (-2.59193146099879641e+01)
  set z 4 1.79258772950371181e-01
  set vx 4 (2.68067772490389322e-03 * daysPerYear)
  set vy 4 (1.62824170038242295e-03 * daysPerYear)
  set vz 4 ((-9.51592254519715870e-05) * daysPerYear)
  set m 4 (5.15138902046611451e-05 * solarMass)
  return $! Bodies x y z vx vy vz m

advance :: Bodies -> IO ()
advance (Bodies !x !y !z !vx !vy !vz !mass) = do
  let pairwise !i !j
        | j >= 5 = if i + 2 < 5 then pairwise (i+1) (i+2) else return ()
        | otherwise = do
            !xi <- get x i; !yi <- get y i; !zi <- get z i
            !xj <- get x j; !yj <- get y j; !zj <- get z j
            let !dx  = xi - xj
                !dy  = yi - yj
                !dz  = zi - zj
                !dsq = dx*dx + dy*dy + dz*dz
                !mag = dt / (dsq * sqrt dsq)
            !mi <- get mass i; !mj <- get mass j
            let !mjmag = mj * mag
                !mimag = mi * mag
            get vx i >>= \v -> set vx i (v - dx * mjmag)
            get vy i >>= \v -> set vy i (v - dy * mjmag)
            get vz i >>= \v -> set vz i (v - dz * mjmag)
            get vx j >>= \v -> set vx j (v + dx * mimag)
            get vy j >>= \v -> set vy j (v + dy * mimag)
            get vz j >>= \v -> set vz j (v + dz * mimag)
            pairwise i (j+1)
  pairwise 0 1
  let updatePos !i
        | i >= 5 = return ()
        | otherwise = do
            !vxi <- get vx i; !vyi <- get vy i; !vzi <- get vz i
            get x i >>= \p -> set x i (p + dt * vxi)
            get y i >>= \p -> set y i (p + dt * vyi)
            get z i >>= \p -> set z i (p + dt * vzi)
            updatePos (i+1)
  updatePos 0
{-# NOINLINE advance #-}

energy :: Bodies -> IO Double
energy (Bodies !x !y !z !vx !vy !vz !mass) = do
  let kinetic !i !acc
        | i >= 5 = return acc
        | otherwise = do
            !vxi <- get vx i; !vyi <- get vy i; !vzi <- get vz i
            !mi  <- get mass i
            kinetic (i+1) (acc + 0.5 * mi * (vxi*vxi + vyi*vyi + vzi*vzi))
  !ke <- kinetic 0 0
  let potential !i !j !acc
        | j >= 5 = if i + 2 < 5 then potential (i+1) (i+2) acc else return acc
        | otherwise = do
            !xi <- get x i; !yi <- get y i; !zi <- get z i
            !xj <- get x j; !yj <- get y j; !zj <- get z j
            !mi <- get mass i; !mj <- get mass j
            let !dx = xi - xj; !dy = yi - yj; !dz = zi - zj
            potential i (j+1) (acc - (mi * mj) / sqrt (dx*dx + dy*dy + dz*dz))
  potential 0 1 ke

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> hPutStrLn stderr "Usage: nbody <iterations>"
    (s:_) -> do
      let !n = read s :: Int
      bodies <- initBodies
      let loop !i
            | i >= n = return ()
            | otherwise = advance bodies >> loop (i+1)
      loop 0
      e <- energy bodies
      hPrintf stderr "%.9f\n" e
