{-# LANGUAGE CPP #-}

module Data.Aeson.Shim (bwd) where

#if MIN_VERSION_aeson(2,0,0)
import Data.HashMap.Strict (HashMap)
import Data.Text (Text)
import qualified Data.Aeson.KeyMap as KM
#endif

-- SEE: https://github.com/phadej/aeson-optics/commit/ff31ca0578482df11002f0cde974ff51b8559e1c
#if MIN_VERSION_aeson(2,0,0)
bwd :: KM.KeyMap v -> HashMap Text v
bwd = KM.toHashMapText
#else
bwd :: a -> a
bwd = id
#endif
