{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE MultiWayIf           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE ViewPatterns         #-}

{-# OPTIONS_GHC -Werror -Wall -fno-warn-orphans #-}

module Frontend.Core
    ( GetH
    , Page, isPrivatePage
    , PageShow(PageShow)
    , Beside(Beside)
    , Frame(Frame, PublicFrame), makeFrame, pageFrame
    , Frame'(Frame', PublicFrame'), makeFrame', pageFrame'
    , FormHandler, FormHandlerT
    , ListItemIdea(ListItemIdea)
    , FormPageView, FormPageResult
    , formAction, redirectOf, makeForm, formPage, redirectFormHandler
    , AuthorWidget(AuthorWidget)
    , CommentVotesWidget(VotesWidget)
    , semanticDiv
    , showed
    , tabSelected
    , html
    , redirect
    )
where

import Control.Lens
import Control.Monad.Except.Missing (finally)
import Control.Monad.Except (MonadError)
import Data.Functor (($>))
import Data.Set (Set)
import Data.String (fromString)
import Data.String.Conversions
import Data.Typeable
import Lucid hiding (href_, script_, src_)
import Lucid.Base
import Servant
import Servant.HTML.Lucid (HTML)
import Servant.Missing (FormH, getFormDataEnv)
import Text.Digestive.View
import Text.Show.Pretty (ppShow)

import qualified Data.Set as Set
import qualified Servant.Missing
import qualified Text.Digestive.Form as DF

import Action
import Api
import Data.UriPath (UriPath, absoluteUriPath)
import Lucid.Missing (script_, href_, src_)
import Types

import qualified Frontend.Path as P


-- | FIXME: Could this be a PR for lucid?
instance ToHtml (HtmlT Identity ()) where
    toHtmlRaw = toHtml
    toHtml = HtmlT . return . runIdentity . runHtmlT

-- | FIXME: Could this be a PR for lucid?
instance ToHtml () where
    toHtmlRaw = toHtml
    toHtml = nil


-- | This will generate the following snippet:
--
-- > <div data-aula="PageIdea"> ... </div>
--
-- Which serves two purposes:
--
--     * It helps the front-en developer to identify which part of the generated pages comes from which
--       combinator
--     * Later on when we write selenium suite, the semantic tags helps up to parse, identify and test
--       elements on the page.
--
-- FIXME: allow attribute list.
semanticDiv :: forall m a. (Monad m, Typeable a) => a -> HtmlT m () -> HtmlT m ()
semanticDiv t = div_ [makeAttribute "data-aula-type" (cs . show . typeOf $ t)]

----------------------------------------------------------------------
-- building blocks

type GetH = Get '[HTML]
type FormHandlerT p a = FormH HTML (FormPage p) a
type FormHandler p = FormHandlerT p ST

-- | Render Form based Views
class FormPageView p where
    type FormPageResult p :: *
    -- | The form action used in form generation
    formAction :: p -> UriPath
    -- | Calculates a redirect address from the given page
    redirectOf :: p -> UriPath
    -- | Generates a Html view from the given page
    makeForm :: (Monad m) => p -> DF.Form (Html ()) m (FormPageResult p)
    -- | Generates a Html snippet from the given view, form action, and the @p@ page
    formPage :: (Monad m) => View (HtmlT m ()) -> ST -> p -> HtmlT m ()

-- | Defines some properties for pages
class Page p where
    isPrivatePage :: p -> Bool

-- | Wrap anything that has 'ToHtml' and wrap it in an HTML body with complete page.
data Frame body = Frame User body | PublicFrame body
  deriving (Functor)

data Frame' body = Frame' User (Html ()) body | PublicFrame' (Html ()) body
  deriving (Functor)

makeFrame :: (ActionPersist r m, ActionUserHandler m, MonadError ActionExcept m, Page p)
          => p -> m (Frame p)
makeFrame p = do
  isli <- isLoggedIn
  if | not isli && isPrivatePage p -> redirect "/login"
     | isPrivatePage p             -> flip Frame p <$> currentUser
     | otherwise                   -> return $ PublicFrame p

-- FIXME: as above
makeFrame' :: (ActionPersist r m, ActionUserHandler m, Page p)
          => Html () -> p -> m (Frame' p)
makeFrame' hdrs p
  | isPrivatePage p = (\u -> Frame' u hdrs p) <$> currentUser
  | otherwise       = return $ PublicFrame' hdrs p

instance (ToHtml body) => ToHtml (Frame body) where
    toHtmlRaw = toHtml
    toHtml (Frame usr bdy)   = pageFrame (Just usr) (toHtml bdy)
    toHtml (PublicFrame bdy) = pageFrame Nothing (toHtml bdy)

instance (ToHtml body) => ToHtml (Frame' body) where
    toHtmlRaw = toHtml
    toHtml (Frame' usr hdrs bdy)   = pageFrame' hdrs (Just usr) (toHtml bdy)
    toHtml (PublicFrame' hdrs bdy) = pageFrame' hdrs Nothing (toHtml bdy)

pageFrame :: (Monad m) => Maybe User -> HtmlT m a -> HtmlT m ()
pageFrame = pageFrame' nil

pageFrame' :: (Monad m) => Html () -> Maybe User -> HtmlT m a -> HtmlT m ()
pageFrame' (HtmlT . return . runIdentity . runHtmlT -> hdrs) mUser bdy = do
    head_ $ do
        title_ "AuLA"
        link_ [rel_ "stylesheet", href_ $ P.TopStatic "css/all.css"]
        hdrs
    body_ [class_ "no-js"] $ do
        _ <- div_ [class_ "page-wrapper"] $ do
            headerMarkup mUser >> bdy
        footerMarkup

headerMarkup :: (Monad m) => Maybe User -> HtmlT m ()
headerMarkup mUser = header_ [class_ "main-header"] $ do
    a_ [class_ "site-logo", title_ "aula", href_ P.Top] nil
    case mUser of
        Just _usr -> do
            ul_ [class_ "main-header-menu"] $ do
                li_ $ a_ [href_ P.ListSpaces] "Ideenräume"
                li_ $ a_ [href_ P.DelegationView] "Beauftragungsnetzwerk"
        Nothing -> nil

    -- FIXME: please add class m-selected to currently selected menu item
    div_ [class_ "main-header-user"] $ do
        case mUser of
            Just usr -> do
                div_ [class_ "pop-menu"] $ do
                        "Hi " <> (usr ^. userLogin . fromUserLogin . html)
                        ul_ [class_ "pop-menu-list"] $ do
                            li_ [class_ "pop-menu-list-item"] . a_ [href_ P.Broken] $ do
                                i_ [class_ "pop-menu-list-icon icon-eye"] nil
                                "Profil anzeigen"
                            li_ [class_ "pop-menu-list-item"] . a_ [href_ P.Broken] $ do
                                i_ [class_ "pop-menu-list-icon icon-sun-o"] nil
                                "Einstellungen"
                            li_ [class_ "pop-menu-list-item"] . a_ [href_ $ P.Admin P.AdminDuration] $ do
                                i_ [class_ "pop-menu-list-icon icon-bolt"] nil
                                "Prozessverwaltung"
                            li_ [class_ "pop-menu-list-item"] . a_ [href_ P.Logout] $ do
                                i_ [class_ "pop-menu-list-icon icon-power-off"] nil
                                "Logout"

            Nothing -> nil
        div_ [class_ "user-avatar"] $ do
            nil
            -- FIXME if avatar is available, replace empty body with this:
            -- img_ [src_ $ P.TopStatic "some_avatar"] nil


footerMarkup :: (Monad m) => HtmlT m ()
footerMarkup = do
    footer_ [class_ "main-footer"] $ do
        ul_ [class_ "main-footer-menu"] $ do
            li_ $ a_ [href_ P.Terms] "Nutzungsbedingungen"
            li_ $ a_ [href_ P.Imprint] "Impressum"
        span_ [class_ "main-footer-blurb"] "Made with ♡ by Liqd"
    script_ [src_ $ P.TopStatic "third-party/modernizr/modernizr-custom.js"]
    script_ [src_ $ P.TopStatic "js/custom.js"]


tabSelected :: Eq tab => tab -> tab -> ST
tabSelected curTab targetTab
    | curTab == targetTab = "tab-selected"
    | otherwise           = "tab-not-selected"

html :: (Monad m, ToHtml a) => Getter a (HtmlT m ())
html = to toHtml

showed :: Show a => Getter a String
showed = to show

data Beside a b = Beside a b

instance (ToHtml a, ToHtml b) => ToHtml (Beside a b) where
    toHtmlRaw (x `Beside` y) = toHtmlRaw x <> toHtmlRaw y
    toHtml    (x `Beside` y) = toHtml    x <> toHtml    y

-- | Debugging page, uses the 'Show' instance of the underlying type.
newtype PageShow a = PageShow { _unPageShow :: a }
    deriving (Show)

instance Page (PageShow a) where
    isPrivatePage _ = True

instance Show a => ToHtml (PageShow a) where
    toHtmlRaw = toHtml
    toHtml = pre_ . code_ . toHtml . ppShow . _unPageShow

-- | FIXME: find better name?
newtype CommentVotesWidget = VotesWidget (Set CommentVote)

instance ToHtml CommentVotesWidget where
    toHtmlRaw = toHtml
    toHtml p@(VotesWidget votes) = semanticDiv p . toHtml $ y <> n
      where
        y = "[up: "   <> show (countVotes Up   commentVoteValue votes) <> "]"
        n = "[down: " <> show (countVotes Down commentVoteValue votes) <> "]"

newtype AuthorWidget a = AuthorWidget (MetaInfo a)

instance (Typeable a) => ToHtml (AuthorWidget a) where
    toHtmlRaw = toHtml
    toHtml p@(AuthorWidget mi) = semanticDiv p . span_ $ do
        "["
        img_ [src_ . P.TopStatic . fromString . cs $ mi ^. metaCreatedByAvatar]
        mi ^. metaCreatedByLogin . fromUserLogin . html
        "]"


data ListItemIdea = ListItemIdea Bool (Maybe Phase) Idea
  deriving (Eq, Show, Read)

instance ToHtml ListItemIdea where
    toHtmlRaw = toHtml
    toHtml p@(ListItemIdea _linkToUserProfile _phase idea) = semanticDiv p $ do
        div_ [class_ "ideas-list-item"] $ do
            a_ [href_ P.Broken] $ do
                -- FIXME use the phase
                div_ [class_ "col-8-12"] $ do
                    div_ [class_ "ideas-list-img-container"] $ do
                        nil
                        -- FIXME if avatar is available, replace empty body with this:
                        -- img_ [src_ $ P.TopStatic "some_avatar"] nil
                    h2_ [class_ "ideas-list-title"] $ do
                        idea ^. ideaTitle . html
                        span_ [class_ "ideas-list-author"] $ "von " <> idea ^. (ideaMeta . metaCreatedByLogin) . fromUserLogin . html
                div_ [class_ "col-4-12 ideas-list-meta-container"] $ do
                    ul_ [class_ "meta-list"] $ do
                        li_ [class_ "meta-list-item"] $ do
                            i_ [class_ "meta-list-icon icon-comment-o"] nil
                            let s = Set.size (idea ^. ideaComments)
                            s ^. showed . html
                            if s == 1 then " Verbesserungsvorschlag" else " Verbesserungsvorschläge"
                        li_ [class_ "meta-list-item"] $ do
                            i_ [class_ "meta-list-icon icon-voting"] nil
                            toHtml (numGivenVotes <> " von " <> numParticipants <> " Stimmen")
                    span_ [class_ "progress-bar"] $ do
                        span_ [ class_ "progress-bar-progress"
                              , style_ ("width: " <> percentageOfVotes <> "%")
                              ]
                            nil
      where
        -- FIXME: extract these from the idea.
        numGivenVotes     = cs $ show (24  :: Int) :: ST
        numParticipants   = cs $ show (600 :: Int) :: ST
        percentageOfVotes = cs $ show (67  :: Int) :: ST

-- | HTML representation of a page generated by digestive functors.
data FormPage p = FormPage p (Html ())

instance Page p => Page (FormPage p) where
    isPrivatePage (FormPage p _h) = isPrivatePage p

instance ToHtml (FormPage p) where
    toHtmlRaw = toHtml
    toHtml (FormPage _p h) = toHtml h

-- | (this is similar to 'formRedirectH' from "Servant.Missing".  not sure how hard is would be to
-- move parts of it there?)
--
-- Note on file upload: The 'processor' argument is responsible for reading all file contents before
-- returning a WHNF from 'popTempCsvFile'.  'cleanupTempCsvFiles' will be called from within this
-- function as a 'processor' finalizer, so be weary of lazy IO!
--
-- Note that since we read (or write to) files eagerly and close them in obviously safe
-- places (e.g., a parent thread of all potentially file-opening threads, after they all
-- terminate), we don't need to use `resourceForkIO`, which is one of the main complexities of
-- the `resourcet` engine and it's use pattern.
redirectFormHandler
    :: (FormPageView p, Page p, ActionM r m)
    => m p                       -- ^ Page representation
    -> (FormPageResult p -> m a) -- ^ Processor for the form result
    -> ServerT (FormHandler p) m
redirectFormHandler getPage processor = getH :<|> postH
  where
    getH = do
        page <- getPage
        let fa = absoluteUriPath $ formAction page
        v <- getForm fa (processor1 page)
        renderer page v fa

    postH formData = do
        page <- getPage
        let fa = absoluteUriPath $ formAction page
            env = getFormDataEnv formData
        (v, mpayload) <- postForm fa (processor1 page) (\_ -> return $ return . runIdentity . env)
        (case mpayload of
            Just payload -> processor2 page payload >>= redirect
            Nothing      -> renderer page v fa)
            `finally` cleanupTempCsvFiles formData

    -- (possibly interesting: on ghc-7.10.3, inlining `processor1` in the `postForm` call above
    -- produces a type error.  is this a ghc bug, or a bug in our code?)
    processor1 = makeForm
    processor2 page result = processor result $> absoluteUriPath (redirectOf page)
    renderer page v fa = FormPage page . toHtml . fmap (formPage v fa) <$> makeFrame page


redirect :: (MonadError ActionExcept m) => ST -> m a
redirect = Servant.Missing.redirect
