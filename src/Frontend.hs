{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -Werror #-}

module Frontend
where

import Data.Maybe
import Control.Exception
import Control.Lens ((^.), (&), (.~), (%~), _Left, view)
import Control.Monad.IO.Class
import Control.Monad.Trans.Except (ExceptT(ExceptT))
import Control.Monad (when, filterM, forM_)
import Data.Aeson (Value(String), ToJSON(toJSON), (.=), encode, object)
import Data.CaseInsensitive (CI, mk, foldCase, foldedCase)
import Data.List (nubBy)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy(Proxy))
import Data.Set (Set)
import Data.String.Conversions
import Data.String.Conversions (SBS, ST, cs, (<>))
import Data.String (fromString)
import Data.Text.Encoding (decodeUtf8')
import Data.Typeable
import Data.Typeable (Typeable)
import Data.Void (Void, absurd)
import Network.HTTP.Types (Header, methodGet, methodHead, methodPost, ok200, statusCode)
import Network.Wai (Application, Middleware, Request, requestHeaders, requestMethod, responseHeaders, responseStatus)
import Network.Wai.Handler.Warp (runSettings, setHost, setPort, defaultSettings)
import Network.Wai.Internal (Response(ResponseFile, ResponseBuilder, ResponseStream, ResponseRaw))
import Servant
import Servant.API ((:>))
import Servant.API.ContentTypes (AllCTRender)
import Servant.HTML.Blaze
import Servant.Server
import Servant.Server.Internal
import Servant.Server.Internal.ServantErr
import Servant.Utils.Links (HasLink(MkLink, toLink), linkURI)
import Servant.Utils.StaticFiles
import Test.QuickCheck
import Text.Blaze
import System.IO
import System.Process
import System.FilePath
import System.Directory
import Text.Blaze.Renderer.Pretty (renderMarkup)
import Text.Show.Pretty (ppShow)
import System.IO.Unsafe (unsafePerformIO)

import qualified Blaze.ByteString.Builder as Builder
import qualified Data.Binary as Binary
import qualified Data.ByteString.Char8 as SBS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Set as Set
import qualified Data.Text as ST
import qualified Network.HTTP.Types.Header as HttpTypes
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

import Arbitrary
import Config
import Types


runFrontend :: IO ()
runFrontend = runSettings settings $ serve (Proxy :: Proxy FrontendH) frontendH
  where
    settings = setHost (fromString $ Config.config ^. listenerInterface)
             . setPort (Config.config ^. listenerPort)
             $ defaultSettings

type GetH = Get '[HTML] H.Html

type FrontendH =
       GetH
  :<|> Raw

frontendH :: Server FrontendH
frontendH =
       return (frame $ H.text "yihaah!")
  :<|> serveDirectory (Config.config ^. htmlStatic)

frame :: H.Html -> H.Html
frame payload = do
    H.head $ do
        H.title $ H.text "AuLA"
        H.link H.! A.rel "stylesheet" H.! A.href "/screen.css"
    H.body $ do
        payload


----------------------------------------------------------------------

-- | Remove existing samples and generate new ones.
recreateSamples :: IO ()
recreateSamples = do
    let path = Config.config ^. Config.htmlStatic </> "samples"
    createDirectoryIfMissing False path
    setCurrentDirectory path
    system "rm -f *.hs *.html"
    samplePages >>= mapM_ writeSample . zip [0..]
    refreshSamples
  where
    writeSample (ix, (typeRep, valueRepShow)) = do
        let fn :: FilePath
            fn | ix < 100 = (reverse . take 3 . reverse $ "000" ++ show ix ++ "_")
                         ++ show' typeRep

            show' :: (Show a) => a -> String
            show' = map f . show
              where
                f ' ' = '_'
                f c = c

        writeFile (fn <.> "hs")            $ valueRepShow
        writeFile (fn <.> "hs" <.> "html") $ "<pre>" <> valueRepShow <> "</pre>"


-- | Read existing samples and re-render the HTML.
refreshSamples :: IO ()
refreshSamples = do
    let path = Config.config ^. Config.htmlStatic </> "samples"
    setCurrentDirectory path

    -- read *.bin
    bins <- filter ((== ".hs") . takeExtension) <$> getDirectoryContents "."

    -- write *.html
    forM_ bins $ \fn -> do
        let fn' = dropExtension fn <.> ".html"
        readFile fn >>= writeFile fn' . dynamicRender

-- | Take a binary serialization and use current 'ToMarkup' instances for
dynamicRender :: String -> String
dynamicRender s = case catMaybes [ g (Proxy :: Proxy Comment)
                                 , g (Proxy :: Proxy Idea)
                                 , g (Proxy :: Proxy (IdeaSpace Topic))
                                 , g (Proxy :: Proxy (IdeaSpace Class))
                                 , g (Proxy :: Proxy (IdeaSpace School))
                                 ] of
    (v:_) -> v
  where
    g :: forall a. (Read a, ToMarkup a) => Proxy a -> Maybe String
    g proxy = unsafePerformIO $ violate (f proxy s) `catch` (\(SomeException _) -> return Nothing)
      where
        violate s = length s `seq` return (Just s)

    f :: forall a. (Read a, ToMarkup a) => Proxy a -> String -> String
    f Proxy = renderMarkup . frame . H.toHtml . (read :: String -> a)

samplePages :: IO [(TypeRep, String)]
samplePages = sequence
    [ f <$> (generate arbitrary :: IO Comment)
    , f <$> (generate arbitrary :: IO Comment)
    , f <$> (generate arbitrary :: IO Comment)
    , f <$> (generate arbitrary :: IO Idea)
    , f <$> (generate arbitrary :: IO Idea)
    , f <$> (generate arbitrary :: IO Idea)
    , f <$> (generate arbitrary :: IO (IdeaSpace Topic))
    , f <$> (generate arbitrary :: IO (IdeaSpace Topic))
    , f <$> (generate arbitrary :: IO (IdeaSpace Class))
    , f <$> (generate arbitrary :: IO (IdeaSpace Class))
    , f <$> (generate arbitrary :: IO (IdeaSpace School))
    , f <$> (generate arbitrary :: IO (IdeaSpace School))
    ]
  where
    f :: (Typeable a, Show a, ToMarkup a) => a -> (TypeRep, String)
    f x = (typeOf x, terminatingShow x)

    terminatingShow :: (Show a) => a -> String
    terminatingShow x = if length s < n then s else error e
      where
        n = 1000000
        s = take n $ ppShow x
        e = "terminatingShow: " ++ s


----------------------------------------------------------------------

instance ToMarkup Comment where
    toMarkup comment = H.div $ do
        H.div $ do
            H.span . toMarkup . AuthorWidget $ comment ^. commentMeta
            H.span . toMarkup . VotesWidget  $ comment ^. commentVotes
        H.div $ do
            toMarkup $ comment ^. commentArticle
        H.div $ do
            H.span $ H.text "[antworten]"
            H.span $ H.text "[melden]"


instance ToMarkup Idea where
    toMarkup idea = H.div $ do
        H.h2 . H.text $ idea ^. ideaTitle

        H.div . H.string . show $ idea ^. ideaCategory

        -- von X / X stimmen / X verbesserungvorschläge
        H.div $ do
            H.span . H.text $ "von " <> (cs . show $ idea ^. ideaMeta . metaCreatedBy )
            H.span . H.text $ "/"
            H.span . H.string $ (show . Set.size $ idea ^. ideaVotes) <> " Stimmen"
            H.span . H.text $ "/"
            H.span . H.string $ (show . Set.size $ idea ^. ideaComments) <> " Verbesserungsvorschläge"

        -- balken: pro, kontra
        H.div . H.pre $ do
            let y = yesVotes $ idea ^. ideaVotes
                n = noVotes  $ idea ^. ideaVotes
            H.div $ do
                H.span . H.string $ "    " <> replicate y '+' <> ":" <> replicate n '-'
            H.div $ do
                H.span . H.string $ replicate (4 + y - length (show y)) ' ' <> show y <> ":" <> show n

        -- buttons
        H.div $ do
            H.button H.! A.value "yes"     $ H.text "dafür"
            H.button H.! A.value "neutral" $ H.text "neutral"
            H.button H.! A.value "no"      $ H.text "dagegen"

        -- article
        H.div . toMarkup $ idea ^. ideaArticle

        -- comments
        H.div $ do
            H.hr
            H.span . H.string $ (show . Set.size $ idea ^. ideaComments) <> " Verbesserungsvorschläge"
            H.span $ H.button H.! A.value "create_comment" $ H.text "Neuer Verbesserungsvorschlag"
            H.hr
            sequence_ . (toMarkup <$>) . Set.toList $ idea ^. ideaComments


instance ToMarkup (IdeaSpace Topic) where
    toMarkup = H.p . H.string . show . typeOf

instance ToMarkup (IdeaSpace Class) where
    toMarkup = H.p . H.string . show . typeOf

instance ToMarkup (IdeaSpace School) where
    toMarkup = H.p . H.string . show . typeOf

instance ToMarkup Article where
    toMarkup = H.div . mapM_ (H.p . H.text) . fromArticle


----------------------------------------------------------------------

newtype VotesWidget = VotesWidget (Set Vote)

instance ToMarkup VotesWidget where
    toMarkup (VotesWidget votes) = H.string $ y ++ n
      where
        y = "[yes: " <> show (yesVotes votes) <> "]"
        n = "[no: " <> show (noVotes votes) <> "]"

newtype AuthorWidget = AuthorWidget MetaInfo

instance ToMarkup AuthorWidget where
    toMarkup (AuthorWidget mi) = H.text $ "[author: " <> (cs . show $ mi ^. metaCreatedBy) <> "]"


----------------------------------------------------------------------

yesVotes :: Set Vote -> Int
yesVotes = Set.size . Set.filter ((== Just True) . view voteValue)

noVotes :: Set Vote -> Int
noVotes = Set.size . Set.filter ((== Just False) . view voteValue)

neutralVotes :: Set Vote -> Int
neutralVotes = Set.size . Set.filter ((== Nothing) . view voteValue)
