{-# LANGUAGE TemplateHaskell     #-}


module Phoityne.VSCode.TH.TerminatedEventBodyJSON where

import Data.Aeson.TH

import Phoityne.VSCode.Utility

-- |
--   Event message for "terminated" event types.
-- The event indicates that debugging of the debuggee has terminated.
--
data TerminatedEventBody =
  TerminatedEventBody {
    restartTerminatedEventBody :: Bool  -- A debug adapter may set 'restart' to true to request that the front end restarts the session.
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions { fieldLabelModifier = rdrop (length "TerminatedEventBody") } ''TerminatedEventBody)

defaultTerminatedEventBody :: TerminatedEventBody
defaultTerminatedEventBody = TerminatedEventBody False

