{-# OPTIONS_GHC -Werror -Wall #-}

module Frontend.Testing
where

import Control.Lens ((^.))

import Action
import Persistent
import Types

-- | Make a topic timeout if the timeout is applicable for the topic.
-- FIXME: Make timeout the jury phase too.
makeTopicTimeout :: (ActionPersist r m, ActionUserHandler m) => AUID Topic -> m ()
makeTopicTimeout tid = do
    Just topic <- persistent $ findTopic tid -- FIXME: 404
    case topic ^. topicPhase of
        PhaseRefinement _ -> topicInRefinementTimedOut tid
        _                 -> return ()
