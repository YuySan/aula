{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-orphans #-}

module Frontend.Page.AdminSpec
where

import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

import qualified Data.ByteString.Lazy as LBS
import qualified Codec.Archive.Zip as Zip

import Logger.EventLog
import Config
import AulaTests


-- | Unpack a zip archive, read the only file contained therein, and call argument on the body.
zipArchiveShouldContain :: String -> Response LBS -> Expectation
zipArchiveShouldContain needle resp = extract resp `shouldContain` needle
  where
    extract :: Response LBS -> String
    extract = cs . Zip.fromEntry . (\(Zip.Archive [es] _ _) -> es) . Zip.toArchive . view responseBody


spec :: Spec
spec = do
    describe "EventLog" . around withServerWithEventLog $ do
        let shouldHaveHeaders = zipArchiveShouldContain . cs $
                LBS.intercalate "," eventLogItemCsvHeaders
            trigger wreq = post wreq "/admin/topic/5/next-phase" ([] :: [Part])

        context "unfiltered" . it "responds with data" $ \wreq -> do
            _ <- trigger wreq
            get wreq "/admin/downloads/events"
                `shouldRespond` [codeShouldBe 200, shouldHaveHeaders]

        context "filtered on existing idea space" . it "responds with data" $ \wreq -> do
            _ <- trigger wreq
            get wreq "/admin/downloads/events?space=school"
                `shouldRespond` [codeShouldBe 200, shouldHaveHeaders]

        context "filtered on non-existent idea space" . it "responds with empty" $ \wreq -> do
            _ <- trigger wreq
            get wreq "/admin/downloads/events?space=2016-980917"
                `shouldRespond` [codeShouldBe 200, zipArchiveShouldContain "[Keine Daten]"]
                -- (it would be nicer to respond with 404 here, but nothing bad should happen with
                -- the status quo either, and as long as the admin uses the UI, this shouldn't ever
                -- happen.)

        context "filtered with bad idea space identifier" . it "responds with unfiltered data" $ \wreq -> do
            _ <- trigger wreq
            get wreq "/admin/downloads/events?space=no-such-space"
                `shouldRespond` [codeShouldBe 200, shouldHaveHeaders]

        -- missing test: test empty event log.


-- | Run 'withServer'' on a aula events file.  It is important that 'genInitialTestDb' is run at
-- startup in 'withServer'' so the event log won't be empty.
withServerWithEventLog :: (WreqQuery -> IO a) -> IO a
withServerWithEventLog action = withSystemTempFile "aula-test-events" $ \elpath h -> do
    hClose h
    cfg <- (logging . eventLogPath .~ elpath) <$> testConfig
    withServer' cfg $ \wreq -> do
        loginAsAdmin wreq
        action wreq
