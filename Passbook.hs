{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE PackageImports       #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}


{- |This module provides different functions to sign a Passbook 'Pass'.

    /Please read the documentation!/

    One set of functions uses the @signpass@ tool included in Apple's Passbook
    Support Materials to sign the pass. This uses the system keychain directly, but
    works on OS X only.

    The other set of functions uses OpenSSL instead, in this case you need to export
    your certificate using the process described in the OpenSSL section of this document.

    If you want to use this module with an existing .pkpass file, you can import it
    using the function 'loadPass'. Please note that you still need to provide the
    assets in a separate directory, 'loadPass' only parses the @pass.json@ file.

    Using these function is very simple, assuming you have created a 'Pass' called
    @myPass@ and you have the related assets (e.g. the logo.png and icon.png files)
    stored in a folder named @myPass/@.

    You want the signed pass to be stored in a folder called @passes/@. You call
    'signpass' like this:

   > (path, passId) <- signpass "myPass" "passes" myPass

    You will find the pass at @path@ with the filename @passId.pkpass@. Using the
    types from "Passbook.Types" ensures that passes are generated correctly.

    Please note that an @icon.png@ file /must be/ present in your asset folder,
    otherwise the generated pass will not work. This is /not/ checked by this module.

    Refer to Apple's Passbook documentation at <https://developer.apple.com/passbook/>
    for more information or to retrieve the @signpass@ tool which is included in the
    Passbook Support Materials. (iOS Developer Membership necessary)

-}
module Passbook ( -- * Sign using signpass
                  -- $signpass
                  signpass
                , signpassWithId
                , signpassWithModifier
                  -- * Sign using OpenSSL
                  -- $openssl
                , signOpen
                , signOpenWithModifier
                , signOpenWithId
                  -- * Helper functions
                , genPassId
                , updateBarcode
                , loadPass
                , module Passbook.Types ) where

import           Codec.Archive.Zip
import           Control.Monad             (liftM)
import           Control.Monad.IO.Class    (liftIO)
import           Data.Aeson
import           Data.Binary               (Word32)
import           Data.Bits                 (shiftR, (.&.))
import qualified Data.ByteString.Lazy      as LB
import           Data.Char                 (intToDigit)
import           Data.Conduit
import           Data.Conduit.Binary       hiding (sinkFile)
import           "filesystem-conduit" Data.Conduit.Filesystem
import           Control.Monad.Trans.Resource
import qualified Data.Text                 as ST
import           Data.Text.Lazy            (Text)
import qualified Data.Text.Lazy            as LT
import           Data.UUID
import           Filesystem.Path           (filename)
import           Filesystem.Path.CurrentOS (encodeString, decodeString)
import           Passbook.Types
import           Prelude                   hiding (FilePath)
import           Shelly (FilePath)
import           Shelly
import           System.Directory          (doesFileExist)
import           System.Random

default (LT.Text)

-- $signpass
--  These functions sign a 'Pass' using the @signpass@ tool provided by Apple in the
--  Passbook Support Materials. You can find those at <https://developer.apple.com/passbook/>
--  however, an iOS Developer Membership is necessary for the download.
--
--  The signpass utility needs access to your keychain. OS X will prompt you for this the first
--  time you run the tool.
--
--  Please make sure that the @signpass@ tool is within your $PATH. These functions work on OS X
--  only.

-- |Takes the filepaths to the folder containing the path assets
--  and the output folder, a 'Pass' and uses a random UUID to
--  create and sign the pass.
--
--  /Important:/ OS X only!
signpass :: FilePath -- ^ Input file path (asset directory)
         -> FilePath -- ^ Output file path
         -> Pass -- ^ The pass to sign
         -> IO (FilePath, ST.Text) -- ^ The filepath of the signed .pkpass and its UUID
signpass passIn passOut pass = do
    passId <- genPassId
    passPath <- signpassWithId passId passIn passOut pass
    return (passPath, passId)

-- |Works like 'signpass', except for the fourth argument which is a
--  modifier function that updates the pass with the generated UUID.
--  This is useful for cases where you want to store the UUID in the barcode
--  or some other field on the pass as well.
--
--  An example function for use with this is 'updateBarcode'.
--
--  /Important:/ OS X only!
signpassWithModifier :: FilePath -- ^ Input file path (asset directory)
                     -> FilePath -- ^ Output file path
                     -> Pass -- ^ The pass to sign
                     -> (ST.Text -> Pass -> Pass) -- ^ Modifier function
                     -> IO (FilePath, ST.Text) -- ^ The filepath of the signed .pkpass and its UUID
signpassWithModifier passIn passOut pass modifier = do
    passId <- genPassId
    passPath <- signpassWithId passId passIn passOut $ modifier passId pass
    return (passPath, passId)

-- |Updates the barcode in a pass with the UUID. This can be passed to 'signpassWithModifier'
--  or 'signOpenWithModifier'.
updateBarcode :: ST.Text -> Pass -> Pass
updateBarcode n p = case barcode p of
    Nothing -> p -- This pass has no barcode.
    Just ob -> p { barcode = Just ob { altText = Just n
                                     , message = n } }

-- |Signs the 'Pass' using the provided ID, no random UUID generation happens here.
--
--  /Important:/ OS X only!
signpassWithId :: ST.Text -- ^ The pass ID
               -> FilePath -- ^ Input file path (asset directory)
               -> FilePath -- ^ Output file path
               -> Pass -- ^ The pass to sign
               -> IO FilePath
signpassWithId passId passIn passOut pass = shelly $ do
    let tmp = passOut </> passId
        lazyId = LT.fromStrict passId
    cp_r passIn tmp
    liftIO $ renderPass (tmp </> ((Shelly.fromText "pass.json") :: FilePath)) pass { serialNumber = passId }
    signcmd lazyId tmp passOut
    rm_rf tmp
    return (passOut </> LT.unpack (LT.append lazyId ".pkpass"))

-- |Helper function to generate a hash
genHash :: FilePath -> Sh (Text, Text)
genHash file = do
    rawhash <- run "openssl" ["sha1", toTextIgnore file]
    let hash = LT.drop 1 $ LT.dropWhile (/= ' ') (LT.fromStrict rawhash)
    return (LT.fromStrict (toTextIgnore $ encodeString $ filename (decodeString file)), LT.filter (/= '\n') hash)

-- |Render JSON and put it in a file
saveJSON :: ToJSON a => a -> FilePath -> IO ()
saveJSON json path = LB.writeFile (ST.unpack $ toTextIgnore path) $ encode json

-- |Helper function to sign the manifest
sslSign :: FilePath -- ^ Certificate
        -> FilePath -- ^ Key
        -> FilePath -- ^ Temporary directory containing manifest.json
        -> Sh ST.Text
sslSign cert key  tmp =
    run "openssl" [ "smime", "-binary"
                  , "-sign"
                  , "-signer", toTextIgnore cert
                  , "-certfile", "wwdr.pem"
                  , "-inkey" , toTextIgnore key
                  , "-in", "manifest.json"
                  , "-out", "signature"
                  , "-outform", "DER" ]

-- $openssl
--   These functions sign a 'Pass' using OpenSSL. They work on operating systems
--   other than OS X as well. To use these you need to export your certificate
--   from the keychain. Assuming you have saved the certificatea as @cert.p12@
--   , the conversion works like this:
--
-- > $ openssl pkcs12 -in cert.p12 -clcerts -nokeys -out certificate.pem
-- > $ openssl pkcs12 -in cert.p12 -nocerts -out keypw.pem
--
--   Enter a password for your key file, you will only need this once in the next step.
--   Then strip the password from your key file using:
--
-- > $ openssl rsa -in keypw.pem -out key.pem
--
--   /Important:/ All paths passed to these functions /must/ be absolute.


-- |Takes the filepaths to the folder containing the path assets
--  and the output folder, the paths to the certificate and the key,
--  a 'Pass' and uses a random UUID to create and sign the pass.
signOpen :: FilePath -- ^ Input file path (asset directory)
         -> FilePath -- ^ Output folder
         -> FilePath -- ^ Certificate
         -> FilePath -- ^ Certificate key
         -> Pass     -- ^ The pass to sign
         -> IO (FilePath, ST.Text) -- ^ The signed .pkpass file and ID
signOpen passIn passOut cert key pass = do
    passId <- genPassId
    passPath <- signOpenWithId passIn passOut cert key pass passId
    return (passPath, passId)

-- |Works like 'signOpen', except for the fourth argument which is a
--  modifier function that updates the pass with the generated UUID.
--  This is useful for cases where you want to store the UUID in the barcode
--  or some other field on the pass as well.
--
--  An example function for use with this is 'updateBarcode'.
signOpenWithModifier :: FilePath -- ^ Input file path (asset directory)
                     -> FilePath -- ^ Output folder
                     -> FilePath -- ^ Certificate
                     -> FilePath -- ^ Certificate key
                     -> Pass     -- ^ The pass to sign
                     -> (ST.Text -> Pass -> Pass) -- ^ Modifier function
                     -> IO (FilePath, ST.Text) -- ^ The signed .pkpass file and ID
signOpenWithModifier passIn passOut cert key pass f = do
    passId <- genPassId
    passPath <- signOpenWithId passIn passOut cert key (f passId pass) passId
    return (passPath, passId)

-- |Signs the 'Pass' using the provided ID, no random UUID generation happens here.
signOpenWithId :: FilePath -- ^ Input file path (asset directory)
               -> FilePath -- ^ Output folder
               -> FilePath -- ^ Certificate
               -> FilePath -- ^ Certificate key
               -> Pass     -- ^ The pass to sign
               -> ST.Text  -- ^ The pass ID
               -> IO FilePath -- ^ The signed .pkpass file
signOpenWithId passIn passOut cert key pass passId = shelly $ silently $ do
    let tmp = passOut </> passId
        passFile = LT.append (LT.fromStrict $ passId) ".pkpass"
    cp_r passIn tmp
    liftIO $ renderPass (tmp </> Shelly.fromText ("pass.json" :: ST.Text)) (pass { serialNumber = passId })
    cd tmp
    manifest <- liftM Manifest $ pwd >>= ls >>= mapM genHash
    liftIO $ saveJSON manifest (tmp </> ("manifest.json" :: FilePath))
    sslSign cert key tmp
    files <- liftM (map (\f -> toTextIgnore (encodeString $ filename (decodeString f)))) $ ls =<< pwd
    run "zip" ((toTextIgnore $ passOut </> (LT.unpack passFile)) : files)
    rm_rf tmp
    return (passOut </> (LT.unpack passFile))

-- |Generates a random UUID for a Pass using "Data.UUID" and "System.Random"
genPassId :: IO ST.Text
genPassId = liftM (ST.pack . showPassId) randomIO

-- |Shows a UUID without the hyphens
showPassId :: UUID -> String
showPassId uuid = let (w0, w1, w2, w3) = toWords uuid
                  in hexw w0 $ hexw' w1 $ hexw' w2 $ hexw w3 ""
    where hexw :: Word32 -> String -> String
          hexw  w s = hexn w 28 : hexn w 24 : hexn w 20 : hexn w 16
                    : hexn w 12 : hexn w  8 : hexn w  4 : hexn w  0 : s

          hexw' :: Word32 -> String -> String
          hexw' w s = hexn w 28 : hexn w 24 : hexn w 20 : hexn w 16
                    : hexn w 12 : hexn w  8 : hexn w  4 : hexn w  0 : s

          hexn :: Word32 -> Int -> Char
          hexn w r = intToDigit $ fromIntegral ((w `shiftR` r) .&. 0xf)


-- |Render and store a pass.json at the desired location.
renderPass :: FilePath -> Pass -> IO ()
renderPass path pass =
    let rendered = sourceLbs $ encode pass
    in runResourceT $ rendered $$ sinkFile (decodeString path)

-- |Call the signpass tool.
signcmd :: Text -- ^ The pass identifier / serial number to uniquely identify the pass
        -> FilePath -- ^ The temporary asset folder.
        -> FilePath -- ^ The output folder for all .pkpass files
        -> Sh ()
signcmd uuid assetFolder passOut =
    run_ "signpass" [ "-p", toTextIgnore assetFolder -- The input folder
                    , "-o", toTextIgnore $ passOut </> LT.unpack (LT.append uuid ".pkpass") ] -- Name of the output file

-- |Tries to parse the pass.json file contained in a .pkpass into a valid
--  'Pass'. If Passbook accepts the .pkpass file, this function should never
--  return @Nothing@.
loadPass :: FilePath -- ^ Location of the .pkpass file
         -> IO (Maybe Pass)
loadPass path = do
    archive <- liftM toArchive $ LB.readFile $ path
    case findEntryByPath "pass.json" archive of
        Nothing   -> return Nothing
        Just pass -> return $ decode $ fromEntry pass
