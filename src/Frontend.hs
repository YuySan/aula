{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -Werror -Wall #-}

module Frontend
where

import Control.Monad.Trans.Except (ExceptT)
import Network.Wai.Handler.Warp (runSettings, setHost, setPort, defaultSettings)
import Servant
import Servant.HTML.Blaze
import Test.QuickCheck (generate, arbitrary)
import Text.Blaze.Html (Html, toMarkup, text)
import Text.Digestive.Form ((.:))
import Text.Digestive.View (View)

import qualified Text.Digestive.Blaze.Html5 as DF
import qualified Text.Digestive.Form as DF

import Servant.Missing
import Thentos.Prelude

import Api.Persistent
import Arbitrary ()
import Config
import Frontend.Html
import Types


runFrontend :: IO ()
runFrontend = runSettings settings $ serve (Proxy :: Proxy FrontendH) frontendH
  where
    settings = setHost (fromString $ Config.config ^. listenerInterface)
             . setPort (Config.config ^. listenerPort)
             $ defaultSettings

type GetH = Get '[HTML]

type FrontendH =
       GetH (Frame String)
  :<|> "ideas" :> "create_random" :> GetH (Frame String)
  :<|> "ideas" :> GetH (Frame PageIdeasOverview)
  :<|> "ideas" :> "create" :> FormH HTML Html ST
  :<|> Raw

frontendH :: Server FrontendH
frontendH =
       return (Frame "yihaah!")
  :<|> (liftIO $ generate arbitrary >>= runPersist . addIdeaH >> return (Frame "new idea created."))
  :<|> (liftIO . runPersist $ Frame . PageIdeasOverview <$> getIdeasH)
  :<|> myFirstForm
  :<|> serveDirectory (Config.config ^. htmlStatic)


-- FIXME: would it be possible to have to html type params for 'FormH'?  one for the result of r,
-- and one for the result of p2?  then the result of p2 could have any 'ToMarkup' instance.
myFirstForm :: Server (FormH HTML Html ST)
myFirstForm = formH "/ideas/create" p1 p2 r
  where
    p1 :: DF.Form Html (ExceptT ServantErr IO) ST
    p1 = "title" .: DF.text Nothing

    p2 :: ST -> ExceptT ServantErr IO Html
    p2 title = liftIO $ do
        idea <- (ideaTitle .~ title) <$> generate arbitrary
        runPersist $ addIdeaH idea
        return . toMarkup . Frame . text $ title

    r :: View Html -> ST -> ExceptT ServantErr IO Html
    r v formAction = pure . DF.form v formAction $ do
        DF.label "title" v "Title:"
        DF.inputText "title" v
        DF.inputSubmit "create idea"
