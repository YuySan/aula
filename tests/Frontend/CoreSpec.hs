{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-missing-signatures -fno-warn-incomplete-patterns #-}

module Frontend.CoreSpec where

import Prelude hiding ((.))
import Control.Arrow((&&&))
import Control.Category ((.))
import Data.List
import Data.String.Conversions
import Data.Typeable (typeOf)
import Test.QuickCheck
import Test.QuickCheck.Monadic (PropertyM, assert, monadicIO, run, pick)
import Text.Digestive.Types
import Text.Digestive.View

import qualified Data.Text.Lazy as LT
import qualified Text.Digestive.Lucid.Html5 as DF

import Action
import Action.Implementation
import Arbitrary (arb, arbPhrase, forAllShrinkDef, schoolClasses)
import Config
import Frontend.Core
import Frontend.Fragment.Comment
import Frontend.Page
import Frontend.Path (relPath)
import Logger (nullLog)
import Persistent.Idiom (listInfoForIdeaIt)
import Types

import AulaTests


-- * list all types for testing

spec :: Spec
spec = do

    -- FIXME: use the lists generated by the haddocks for Page and FormPage classes to make sure these
    -- lists are complete.

    describe "ToHtml" $ mapM_ checkToHtmlInstance [
          H (arb :: Gen PageOverviewOfSpaces)
        , H (arb :: Gen PageOverviewOfWildIdeas)
        , H (arb :: Gen PageOverviewOfTopics)
        , H (arb :: Gen ViewTopic)
        , H (arb :: Gen ViewIdea)
        , H (arb :: Gen PageUserProfileCreatedIdeas)
        , H (arb :: Gen PageUserProfileDelegatedVotes)
        , H (arb :: Gen AdminViewUsers)
        , H (arb :: Gen AdminViewClasses)
        , H (arb :: Gen PageDelegateVote)
        , H (arb :: Gen PageDelegationNetwork)
        , H (arb :: Gen PageStaticImprint)
        , H (arb :: Gen PageStaticTermsOfUse)
        , H (arb :: Gen AdminEditClass)
        , H (arb :: Gen CommentWidget)
        ]
    describe "PageFormView" $ mapM_ testForm
          -- admin forms
        [ F (arb :: Gen PageAdminSettingsDurations)
        , F (arb :: Gen PageAdminSettingsQuorum)
        , F (arb :: Gen PageAdminSettingsFreeze)
        , F (arb :: Gen PageAdminSettingsEventsProtocol)
--        , F (arb :: Gen AdminEditUser) -- FIXME: Implement dummy persistent
        , F (arb :: Gen AdminDeleteUser)
--        , F (arb :: Gen AdminCreateUser) -- TODO: Investigate issue
        , F (arb :: Gen AdminCreateClass)
        , F (arb :: Gen AdminPhaseChange)
        , F (arb :: Gen PageAdminResetPassword)

          -- idea forms
        , F (arb :: Gen CreateIdea)
        , F (arb :: Gen Frontend.Page.MoveIdea)
        , F (arb :: Gen CommentOnIdea)
        , F (arb :: Gen Frontend.Page.EditIdea)
        , F (arb :: Gen EditComment)
        , F (arb :: Gen JudgeIdea)
        , F (arb :: Gen CreatorStatement)
        , F (arb :: Gen ReportComment)
        , F (arb :: Gen ReportIdea)

          -- login forms
--        , F (arb :: Gen PageHomeWithLoginPrompt) -- FIXME: Implement dummy persistent to fetch data

          -- topic forms
        , F (arb :: Gen CreateTopic)
        , F (arb :: Gen EditTopic)

          -- user forms
--        , F (arb :: Gen PageUserSettings)  -- FIXME cannot fetch the password back from the payload
        , F (arb :: Gen EditUserProfile)
        , F (arb :: Gen ReportUserProfile)
        ]

    -- FIXME: test this in all forms, for all validation errors.
    describe "form validation errors" $ do
        let spc = IdeaLocationSpace SchoolSpace
            page = CreateIdea spc
            payload = ProtoIdea "!@" (Markdown "lorem ipsidiorum!") Nothing spc
          in testValidationError page EmptyPayloadContext payload
            ["Titel der Idee: ung\252ltige Eingabe: &quot;!&quot; (erwartet: Buchstaben, Ziffern, oder Leerzeichen)"]


-- * translate form data back to form input

-- | Translate a value into the select string for the form 'Env'.
--
-- FIXME: none of this is very elegant.  can we improve on it?
-- FIXME: this function does not work for complex ADTs. E.g: 'SchoolClass Int String'
--
-- Text fields in forms are nice because the values in the form 'Env' contains simply the text
-- itself, as it ends up in the parsed form playload.  Selections (pull-down menus) are trickier,
-- because 'Env' maps their path to an internal representation of a reference to the selected item,
-- rather than the human-readable menu entry.
--
-- This function mimics the 'inputSelect' functions internal behavior from the
-- digestive-functors-lucid package: it extracts an enumeration of the input choices from the views,
-- constructs the form field values from that, and looks up the one whose item description matches
-- the given category value.
--
-- Since the item descriptions are available only as 'Html', not as text, and 'Html' doesn't have
-- 'Eq', we need to apply another trick and transform both the category value and the item
-- description to 'LT'.
selectValue :: (Show a, Eq a) => ST -> View (Html ()) -> [(a, LT.Text)] -> a -> ST
selectValue ref v xs x =
    case find test choices of
        Just (i, _, _) -> value i
        Nothing -> error $ unwords ["selectValue: no option found.", show x, show xs]
  where
    ref'    = absoluteRef ref v
    value i = ref' <> "." <> i
    choices = fieldInputChoice ref v
    test (_, sx :: Html (), _) = showValue x == renderText sx
    showValue ((`lookup` xs) -> Just y) = y
    showValue z = error $ unwords ["selectValue: no option found.", show z, show xs]

data EmptyPayloadContext = EmptyPayloadContext
  deriving (Show, Eq)

-- | In order to be able to call 'payloadToEnv', define a `PayloadToEnv' instance.
class PayloadToEnv a where
    type PayloadToEnvContext a :: *
    type PayloadToEnvContext a = EmptyPayloadContext

    payloadDefaultContext :: Proxy a -> PayloadToEnvContext a
    default payloadDefaultContext :: Proxy a -> EmptyPayloadContext
    payloadDefaultContext _ = EmptyPayloadContext

    payloadToEnvMapping   :: PayloadToEnvContext a -> View (Html ()) -> a -> ST -> Action [FormInput]

-- | When context dependent data is constructed via forms with the 'pure' combinator
-- in the form description, in the digestive functors libarary an empty path will
-- be generated. Which is not an issue here. This functions guards against that with
-- the @[""]@ case.
--
-- Example:
--
-- >>> ProtoIdea <$> ... <*> pure ScoolSpave <*> ...
payloadToEnv :: (PayloadToEnv a) => PayloadToEnvContext a -> View (Html ()) -> a -> Env Action
payloadToEnv _ _ _ [""]       = pure []
payloadToEnv c v a ["", path] = payloadToEnvMapping c v a path

instance PayloadToEnv ProtoIdea where
    payloadToEnvMapping _ _v (ProtoIdea t (Markdown d) c _is) = \case
        "title"         -> pure [TextInput t]
        "idea-text"     -> pure [TextInput d]
        "idea-category" -> pure [TextInput $ fromMaybe nil (cs . show . fromEnum <$> c)]

instance PayloadToEnv User where
    payloadToEnvMapping _ _ u = \case
        "user" -> pure [TextInput $ u ^. userLogin . unUserLogin]
        "pass" -> pure []

ideaCheckboxValue iids path =
    if path `elem` (("idea-" <>) . show <$> iids)
        then "on"
        else "off"

instance PayloadToEnv ProtoTopic where
    payloadToEnvMapping _ _ (ProtoTopic title (PlainDocument desc) image _ iids _) path'
        | "idea-" `isPrefixOf` path = pure [TextInput $ ideaCheckboxValue iids path]
        | path == "title" = pure [TextInput title]
        | path == "desc"  = pure [TextInput desc]
        | path == "image" = pure [TextInput image]
      where
        path :: String = cs path'

instance PayloadToEnv EditTopicData where
    payloadToEnvMapping _ _ (EditTopicData title (PlainDocument desc) iids) path'
        | "idea-" `isPrefixOf` path = pure [TextInput $ ideaCheckboxValue iids path]
        | path == "title"           = pure [TextInput title]
        | path == "desc"            = pure [TextInput desc]
      where
        path :: String = cs path'

instance PayloadToEnv UserSettingData where
    payloadToEnvMapping _ _ (UserSettingData email oldpass newpass1 newpass2) = \case
        "email"         -> pure [TextInput $ email ^. _Just . re emailAddress]
        "old-password"  -> pure [TextInput $ fromMaybe "" oldpass]
        "new-password1" -> pure [TextInput $ fromMaybe "" newpass1]
        "new-password2" -> pure [TextInput $ fromMaybe "" newpass2]

instance PayloadToEnv Durations where
    payloadToEnvMapping _ _ (Durations elab vote) = \case
        "elab-duration" -> pure [TextInput (cs . show . unDurationDays $ elab)]
        "vote-duration" -> pure [TextInput (cs . show . unDurationDays $ vote)]

instance PayloadToEnv Quorums where
    payloadToEnvMapping _ _ (Quorums school clss) = \case
        "school-quorum" -> pure [TextInput (cs $ show school)]
        "class-quorum"  -> pure [TextInput (cs $ show clss)]

instance PayloadToEnv Freeze where
    payloadToEnvMapping _ _ b = \case
        "freeze" -> pure [TextInput $ showOption b]
      where
        -- (using internal df keys here is a bit fragile, but it works for now.)
        showOption NotFrozen = "/admin/freeze.freeze.0"
        showOption Frozen    = "/admin/freeze.freeze.1"

instance PayloadToEnv Role where
    payloadToEnvMapping _ v r = \case
        "role"  -> pure [TextInput $ selectValue "role" v roleSelectionChoices (r ^. roleSelection)]
        -- FIXME: Selection does not work for composite types like school class.
        "class" -> pure [TextInput $ selectValue "class" v classes (r ^?! roleSchoolClass)]
      where
        classes = (id &&& cs . view className) <$> schoolClasses

instance PayloadToEnv CommentContent where
    payloadToEnvMapping _ _ (CommentContent (Markdown comment)) = \case
        "note-text" -> pure [TextInput comment]

instance PayloadToEnv AdminPhaseChangeForTopicData where
    payloadToEnvMapping _ v (AdminPhaseChangeForTopicData (AUID tid) dir) = \case
        "topic-id" -> pure [TextInput $ cs (show tid)]
        "dir"      -> pure [TextInput $ selectValue "dir" v dirs dir]
      where
        dirs = (id &&& uilabel) <$> [Forward, Backward]

instance PayloadToEnv IdeaJuryResultValue where
    payloadToEnvMapping _ _ r = \case
        "note-text" -> pure [TextInput $ r ^. ideaResultReason . _Markdown]

instance PayloadToEnv ReportCommentContent  where
    payloadToEnvMapping _ _ (ReportCommentContent (Markdown m)) = \case
        "note-text" -> pure [TextInput m]

instance PayloadToEnv Document  where
    payloadToEnvMapping _ _ (Markdown m) = \case
        "note-text" -> pure [TextInput m]


-- * machine room

data HtmlGen where
    H :: (Show m, Typeable m, ToHtml m, Arbitrary m) => Gen m -> HtmlGen

-- | Checks if the markup rendering does contain bottoms.
checkToHtmlInstance :: HtmlGen -> Spec
checkToHtmlInstance (H g) =
    it (show $ typeOf g) . property . forAllShrinkDef g $ \pageSource ->
        LT.length (renderText (toHtml pageSource)) > 0

data FormGen where
    F :: ( r ~ FormPagePayload m
         , Show m, Typeable m, FormPage m
         , Show r, Eq r, Arbitrary r, PayloadToEnv r
         , ArbFormPagePayload m, Arbitrary m
         , c ~ PayloadToEnvContext r
         , c ~ ArbFormPagePayloadContext m
         , Show c
         ) => Gen m -> FormGen

testForm :: FormGen -> Spec
testForm fg = renderForm fg >> postToForm fg

-- | Checks if the form rendering does not contains bottoms and
-- the view has all the fields defined for GET form creation.
renderForm :: FormGen -> Spec
renderForm (F g) =
    it (show (typeOf g) <> " (show empty form)") . property . forAllShrinkDef g $ \page -> monadicIO $ do
        len <- runFailOnError $ do
            v <- getForm (absoluteUriPath . relPath $ formAction page) (makeForm page)
            return . LT.length . renderText $ formPage v (DF.form v "formAction") page
        assert (len > 0)

simulateForm
    :: forall page payload payloadCtx .
        ( FormPage page
        , PayloadToEnv payload
        , payload ~ FormPagePayload page
        , payloadCtx ~ PayloadToEnvContext payload)
    => page -> payloadCtx -> payload -> IO (View (Html ()), Maybe payload)
simulateForm page ctx payload = do
    let frm = makeForm page
    env <- runFailOnErrorIO $ (\formx -> payloadToEnv ctx formx payload) <$> getForm "" frm
    runFailOnErrorIO $ postForm "" frm (\_ -> pure env)

testValidationError ::
       ( Typeable page, Show payload
       , FormPage page, PayloadToEnv payload
       , payload ~ FormPagePayload page
       , payloadCtx ~ PayloadToEnvContext payload
       )
    => page -> payloadCtx -> payload -> [String] -> Spec
testValidationError page ctx payload expected =
    describe ("validation in form " <> show (typeOf page, payload)) . it "works" $ do
        (v, Nothing) <- simulateForm page ctx payload
        (show . snd <$> viewErrors v) `shouldBe` expected
            -- FIXME: render Html instead of showing it?

runFailOnError :: Action a -> PropertyM IO a
runFailOnError = run . runFailOnErrorIO

runFailOnErrorIO :: Action a -> IO a
runFailOnErrorIO action = do
    cfg <- readConfig nullLog DontWarnMissing
    let env = ActionEnv (error "Dummy RunPersist") cfg nullLog
    unNat (exceptToFail . mkRunAction env) action

-- | Checks if the form processes valid and invalid input a valid output and an error page, resp.
--
-- For valid inputs, we generate an arbitrary value of the type generated by the form parser,
-- translate it back into a form 'Env' with a 'PayloadToEnv' instance, feed that into 'postForm',
-- and compare the parsed output with the generated output.
--
-- For invalid inputs, we have to go about it differently: since we don't expect to get a valid form
-- output, we generate an 'Env' directly that can contain anything expressible in a valid HTTP POST
-- request, including illegal or missing form fields, arbitrary invalid string values etc.  This
-- happens in an appropriate 'ArbitraryBadEnv' instance.  For the test to succeed, we compare the
-- errors in the view constructed by 'postForm' against the expected errors generated along with the
-- bad env.
postToForm :: FormGen -> Spec
postToForm (F g) = do
    it (show (typeOf g) <> " (process valid forms)") . property . monadicIO $ do
        page <- pick g
        ctx <- pick (arbFormPagePayloadCtx page)
        payload <- pick (arbFormPagePayload page)
        (v, mpayload) <- run $ simulateForm page ctx payload
        case mpayload of
            Nothing       -> fail $ unwords
                                ("Form validation has failed:" : map show (viewErrors v))
            Just payload' -> liftIO $ payload' `shouldBe` payload

    -- FIXME: Valid and invalid form data generation should
    -- be separated and have a different type class.
    it (show (typeOf g) <> " (process *in*valid form input)") . property . monadicIO $ do
        page <- pick g
        ctx <- pick (arbFormPagePayloadCtx page)
        mpayload <- pick (arbFormPageInvalidPayload page)
        forM_ mpayload
            (\payload -> do
                (_, mpayload') <- run $ simulateForm page ctx payload
                liftIO $ mpayload' `shouldBe` Nothing)


-- | Arbitrary test data generation of the 'FormPagePayload' associated
-- type from 'FormPage'.
--
-- In some cases the arbitrary data generation depends on the 'Page' context
-- and the 'FormPagePayload' has to compute data from the context.
class FormPage p => ArbFormPagePayload p where
    type ArbFormPagePayloadContext p :: *
    type ArbFormPagePayloadContext p = EmptyPayloadContext

    arbFormPagePayloadCtx :: p -> Gen (ArbFormPagePayloadContext p)
    default arbFormPagePayloadCtx :: p -> Gen EmptyPayloadContext
    arbFormPagePayloadCtx _ = pure EmptyPayloadContext

    -- | Generates valid form inputs.
    arbFormPagePayload :: (r ~ FormPagePayload p, Arbitrary r, Show r) => p -> Gen r
    arbFormPagePayload _ = arbitrary

    -- | Generates invalid form inputs, if possible
    arbFormPageInvalidPayload :: (r ~ FormPagePayload p, Arbitrary r, Show r) => p -> Gen (Maybe r)
    arbFormPageInvalidPayload _ = return Nothing


instance ArbFormPagePayload CreateIdea where
    arbFormPagePayload (CreateIdea location) =
        (set protoIdeaLocation location <$> arbitrary)
        <**> (set protoIdeaDesc <$> arb)

instance ArbFormPagePayload Frontend.Page.EditIdea where
    arbFormPagePayload (Frontend.Page.EditIdea idea) =
        set protoIdeaLocation (idea ^. ideaLocation) <$> arbitrary

instance ArbFormPagePayload CommentOnIdea

instance ArbFormPagePayload PageAdminSettingsQuorum where
    arbFormPagePayload _ = Quorums <$> boundary 1 100
                                   <*> boundary 1 100
    arbFormPageInvalidPayload _ =
        Just <$> (Quorums <$> invalid <*> invalid)
      where
        invalid = oneof
            [ (*(-1)) . abs <$> arbitrary
            , (100+) . getPositive <$> arbitrary
            ]

instance ArbFormPagePayload PageAdminSettingsFreeze

instance ArbFormPagePayload PageAdminSettingsDurations where
    arbFormPagePayload _ = Durations <$> days <*> days
      where
        days = DurationDays . getPositive <$> arbitrary

instance ArbFormPagePayload PageUserSettings

instance ArbFormPagePayload PageHomeWithLoginPrompt

instance ArbFormPagePayload CreateTopic where
    arbFormPagePayload (CreateTopic space ideas _timestamp) =
            set protoTopicIdeaSpace space
          . set protoTopicIdeas (map (^. listInfoForIdeaIt . _Id) ideas)
        <$> arbitrary
        <**> (set protoTopicDesc<$> arb)

instance ArbFormPagePayload Frontend.Page.EditTopic where
    arbFormPagePayload (Frontend.Page.EditTopic _space _topic ideas _preselected) =
        EditTopicData
        <$> arbPhrase
        <*> arbitrary
        -- FIXME: Generate a sublist from the given ideas
        -- Ideas should be a set which contains only once one idea. And the random
        -- result generation should select from those ideas only.
        <*> pure (view (listInfoForIdeaIt . _Id) <$> ideas)
        <**> (set editTopicDesc <$> arb)

instance ArbFormPagePayload AdminEditUser

instance PayloadToEnv AdminEditUserPayload where
    payloadToEnvMapping _ v (AdminEditUserPayload mlogin role) = \case
        "login" -> pure $ view (unUserLogin . to TextInput) <$> maybeToList mlogin
        "role"  -> pure [TextInput $ selectValue "role" v roleSelectionChoices (role ^. roleSelection)]
        "class" -> pure $ TextInput . selectValue "class" v classValues <$> maybeToList (role ^? roleSchoolClass)
      where
        classValues = (id &&& cs . view className) <$> schoolClasses

instance ArbFormPagePayload AdminPhaseChange

instance ArbFormPagePayload CreatorStatement where
    arbFormPageInvalidPayload _ = pure . Just $ Markdown ""

instance ArbFormPagePayload JudgeIdea where
    arbFormPagePayload (JudgeIdea IdeaFeasible    _ _)
        = Feasible <$> frequency [(1, pure Nothing), (10, Just <$> arb)]
    arbFormPagePayload (JudgeIdea IdeaNotFeasible _ _)
        = NotFeasible <$> arb

    arbFormPageInvalidPayload (JudgeIdea IdeaFeasible _ _)
        = pure Nothing
    arbFormPageInvalidPayload (JudgeIdea IdeaNotFeasible _ _)
        = pure . Just . NotFeasible $ Markdown ""

instance ArbFormPagePayload ReportComment where
    arbFormPageInvalidPayload _ = pure . Just . ReportCommentContent $ Markdown ""

instance ArbFormPagePayload ReportUserProfile

instance ArbFormPagePayload EditUserProfile where
    arbFormPagePayload _ =
        UserProfile
        <$> oneof [pure Nothing, Just . (cs :: String -> ST) . getNonEmpty <$> arb]
        <*> arb

instance PayloadToEnv UserProfile where
    payloadToEnvMapping _ _ (UserProfile murl (Markdown desc)) = \case
        "avatar" -> pure $ FileInput . cs <$> maybeToList murl
        "desc"   -> pure [TextInput desc]

-- FIXME: Move ideas to wild is not generated
instance ArbFormPagePayload Frontend.Page.MoveIdea where
    type ArbFormPagePayloadContext Frontend.Page.MoveIdea = [Topic]
    arbFormPagePayloadCtx (MoveIdea _ideas topics) = pure topics
    arbFormPagePayload (MoveIdea _ideas topics) =
        MoveIdeaToTopic <$> Test.QuickCheck.elements (view _Id <$> topics)

instance PayloadToEnv Types.MoveIdea where
    type PayloadToEnvContext Types.MoveIdea = [Topic]
    payloadDefaultContext _ = []
    -- FIXME: MoveIdeaToWild is not handled properly
    payloadToEnvMapping _ _v MoveIdeaToWild      = const $ pure []
    payloadToEnvMapping ts v (MoveIdeaToTopic t) = \case
        "topic-to-move" -> pure [TextInput $ selectValue "topic-to-move" v topicIds t]
      where
        topicIds = (view _Id &&& cs . view topicTitle) <$> ts

instance ArbFormPagePayload EditComment

instance ArbFormPagePayload ReportIdea

instance ArbFormPagePayload PageAdminSettingsEventsProtocol where
    type ArbFormPagePayloadContext PageAdminSettingsEventsProtocol = [IdeaSpace]
    arbFormPagePayloadCtx (PageAdminSettingsEventsProtocol spaces) = pure spaces
    arbFormPagePayload (PageAdminSettingsEventsProtocol [])
        = pure $ EventsProtocolFilter Nothing
    arbFormPagePayload (PageAdminSettingsEventsProtocol spaces)
        = EventsProtocolFilter . Just <$> Test.QuickCheck.elements spaces

instance PayloadToEnv EventsProtocolFilter where
    type PayloadToEnvContext EventsProtocolFilter = [IdeaSpace]
    payloadDefaultContext _ = [SchoolSpace]
    payloadToEnvMapping is v (EventsProtocolFilter mIdeaSpace) = \case
        "space" -> pure [TextInput $ selectValue "space" v vs mIdeaSpace]
      where
        vs :: [(Maybe IdeaSpace, LT.Text)]
        vs = (Nothing, "(Alle Ideenräume)") : ((Just &&& cs . toUrlPiece) <$> is)

instance ArbFormPagePayload AdminDeleteUser

instance PayloadToEnv AdminDeleteUserPayload where
    payloadToEnvMapping _ _ _ = \case
        _ -> pure [TextInput ""]

instance ArbFormPagePayload AdminCreateUser

{- TODO
  1) Frontend.Core.PageFormView Gen AdminCreateUser (process valid forms)
       uncaught exception: ErrorCall (Prelude.!!: index too large) (after 1 test)

instance PayloadToEnv CreateUserPayload where
    payloadToEnvMapping _ _ (CreateUserPayload _firstname _lastname _mlogin _email _role) = \case
        "firstname" -> pure [TextInput "a"]
        "lastname"  -> pure [TextInput "a"]
        -- "login"     -> pure $ view (unUserLogin . to TextInput) <$> maybeToList mlogin
        "login"     -> pure [TextInput "aaaaa"]
        "email"     -> pure [TextInput "a@a.com"]
        "role"      -> pure [TextInput "a"]
        "class"     -> pure [TextInput "a"]
-}

instance ArbFormPagePayload AdminCreateClass where
    arbFormPagePayload _ = BatchCreateUsersFormData <$> arbPhrase <*> arb

instance PayloadToEnv BatchCreateUsersFormData where
    payloadToEnvMapping _ _ (BatchCreateUsersFormData classname mfilepath) = \case
        "classname" -> pure [TextInput classname]
        "file"      -> pure $ FileInput <$> maybeToList mfilepath

instance ArbFormPagePayload PageAdminResetPassword

instance PayloadToEnv InitialPassword where
    payloadToEnvMapping _ _ (InitialPassword pwd) = \case
        "new-pwd" -> pure [TextInput pwd]
