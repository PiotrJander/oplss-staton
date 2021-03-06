{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MHMonad where

import Control.Monad.Trans.Writer
import Control.Monad.State
import Data.Monoid
import System.Random 
import Debug.Trace
import System.IO.Unsafe
import Control.Monad.Extra
  
-- As programs run they write scores (likelihoods: Product Double)
-- and we keep track of the length of each run (Sum Int).
-- We also use randomness, in the form of a list of seeds [Double].
newtype Meas a = Meas (WriterT (Product Double,Sum Int) (State [Double]) a)
  deriving(Functor, Applicative, Monad)

-- Score weights the result, typically by the likelihood of an observation. 
score :: Double -> Meas ()
score r = Meas $ tell $ (Product r,Sum 0)

-- Sample draws a new sample. We first use the given deterministic bits,
-- and then move to the stream of randoms when that is used up.
-- We keep track of the numbers used in any given run.
sample :: Meas Double
sample = Meas $
       do ~(r:rs) <- get
          put rs
          tell $ (Product 1,Sum 1)
          return r

categ :: [Double] -> Double -> Integer
categ rs r = let helper (r':rs') r'' i =
                          if r'' < r' then i else helper rs' (r''-r') (i+1)
           in helper rs r 0

-- Output a stream of weighted samples from a program. 
weightedsamples :: forall a. Meas a -> IO [(a,Double)]
weightedsamples (Meas m) =
                    do let helper :: State [Double]
                                     [(a,(Product Double,Sum Int))]
                           helper = do
                             (x, w) <- runWriterT m
                             rest <- helper
                             return $ (x,w) : rest
                       g <- getStdGen
                       let rs = randoms g
                       let (xws,_) = runState helper rs
                       return $ map (\(x,(w,i)) -> (x,getProduct w)) xws 

getrandom :: State [Double] Double
getrandom = do
  ~(r:rs) <- get
  put rs
  return r

-- Produce a stream of samples, together with their weights,
-- using single site Metropolis Hastings.
mh :: forall a. Meas a -> IO [(a,Product Double)]
mh (Meas m) =
  do -- helper takes a random source and the previous result
     -- and produces a stream of result/weight pairs
     let step :: [Double] -> State [Double] [Double]
         -- each step will use three bits of randomness,
         -- plus any extra randomness needed when rerunning the model
         step as = do
           let ((_, (w,l)),_) =
                 runState (runWriterT m) as 
           -- randomly pick which site to change
           r <- getrandom
           let i = categ (replicate (fromIntegral $ getSum l)
                          (1/(fromIntegral $ getSum l))) r 
           -- replace that site with a new random choice
           r' <- getrandom
           let as' =
                 (let (as1,_:as2) = splitAt (fromIntegral i) as in
                    as1 ++ r' : as2)
           -- rerun the model with the original and changed sites
           let ((_, (w',l')),_) =
                 runState (runWriterT m) (as') 
           -- reverse the list of used numbers, ready to be reused
           let ratio = getProduct w' * (fromIntegral $ getSum l')
                       / (getProduct w * (fromIntegral $ getSum l))
           r'' <- getrandom
           if r'' < (min 1 ratio) then return as' else return as
     g <- getStdGen
     let (g1,g2) = split g
     let (samples,_) = runState (iterateM step (randoms g1)) (randoms g2)
     return $ map (\(x,(w,l)) -> (x,w)) 
       $ map (\as -> fst $ runState (runWriterT m) as)
       $ samples
     
