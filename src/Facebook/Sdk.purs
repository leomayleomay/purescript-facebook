module Facebook.Sdk
  ( defaultConfig
  , Config (..)
  , Status (..)
  , Field (..)
  , StatusInfo (..)
  , AuthResponse (..)
  , UserId (..)
  , UserName (..)
  , UserEmail (..)
  , UserInfo (..)
  , AccessToken (..)
  , Sdk
  , AppId
  , ApiPath
  , ApiMethod (..)
  , LoginOptions (..)
  , Scope (..)
  , init
  , loginStatus
  , login
  , logout
  , api
  , me
  , userInfo
  ) where

import Prelude

import Control.Monad.Error.Class (throwError)
import Control.Monad.Except (runExcept)
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Array (zip)
import Data.Either (Either(..), either, note)
import Data.FoldableWithIndex (foldWithIndexM)
import Data.Function.Uncurried (Fn5, runFn5)
import Data.Generic.Rep (class Generic)
import Data.Map as M
import Data.Maybe (Maybe)
import Data.Newtype (class Newtype, unwrap)
import Data.Show.Generic (genericShow)
import Data.String (joinWith, toLower)
import Data.Traversable (intercalate, traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff as Aff
import Effect.Exception (error)
import Effect.Exception as Exception
import Foreign (F, Foreign, MultipleErrors, readInt, readNullOrUndefined, readString, unsafeToForeign)
import Foreign.Index ((!))
import Foreign.Keys (keys)
import Foreign.Object as SM

type AppId = String

newtype Config = Config
  { appId                :: AppId
  , version              :: String
  , status               :: Boolean
  , cookie               :: Boolean
  , frictionlessRequests :: Boolean
  , hideFlashCallback    :: Boolean
  , autoLogAppEvents     :: Boolean
  , xmlfb                :: Boolean
  , debug                :: Boolean
  , locale               :: String
  }

defaultConfig :: AppId -> Config
defaultConfig appId = Config
  { appId                : appId
  , version              : "v3.1"
  , status               : false
  , cookie               : false
  , frictionlessRequests : false
  , hideFlashCallback    : false
  , autoLogAppEvents     : false
  , xmlfb                : false
  , debug                : false
  , locale               : "en_US"
  }

derive instance eqConfig :: Eq Config
derive instance genericConfig :: Generic Config _
instance showConfig :: Show Config where show = genericShow

data Status = Connected | NotAuthorized | Unknown

derive instance eqStatus :: Eq Status
derive instance genericStatus :: Generic Status _
instance showStatus :: Show Status where show = genericShow

newtype StatusInfo = StatusInfo
  { status       :: Status
  , authResponse :: Maybe AuthResponse
  }

derive instance eqStatusInfo :: Eq StatusInfo
derive instance genericStatusInfo :: Generic StatusInfo _
instance showStatusInfo :: Show StatusInfo where show = genericShow

newtype AccessToken = AccessToken String
derive newtype instance eqAccessToken :: Eq AccessToken
derive newtype instance showAccessToken :: Show AccessToken
derive newtype instance encodeJsonAccessToken :: EncodeJson AccessToken
derive instance genericAccessToken :: Generic AccessToken _

newtype UserId = UserId String
derive newtype instance eqUserId :: Eq UserId
derive newtype instance showUserId :: Show UserId
derive newtype instance encodeJsonUserId :: EncodeJson UserId
derive instance genericUserId :: Generic UserId _

newtype UserName = UserName String
derive newtype instance eqUserName :: Eq UserName
derive newtype instance showUserName :: Show UserName
derive instance genericUserName :: Generic UserName _

newtype UserEmail = UserEmail String
derive newtype instance eqUserEmail :: Eq UserEmail
derive newtype instance showUserEmail :: Show UserEmail
derive instance genericUserEmail :: Generic UserEmail _

newtype AuthResponse = AuthResponse
  { accessToken   :: AccessToken
  , expiresIn     :: Int
  , signedRequest :: String
  , userId        :: UserId
  }

derive instance eqAuthResponse :: Eq AuthResponse
derive instance genericAuthResponse :: Generic AuthResponse _
instance showAuthResponse :: Show AuthResponse where show = genericShow

data Field = Id | Name | Email | Gender | Birthday
derive instance eqField :: Eq Field
derive instance genericField :: Generic Field _
derive instance ordField :: Ord Field
instance showField :: Show Field where
  show Id = "Id"
  show Name = "Name"
  show Email = "Email"
  show Gender = "Gender"
  show Birthday = "Birthday"

readField :: String -> Either String Field
readField "id" = Right Id
readField "name" = Right Name
readField "email" = Right Email
readField "gender" = Right Gender
readField "birthday" = Right Birthday
readField field = Left $ "Unknown field in the Facebook Graph API response (" <> field <> ")"

newtype UserInfo = UserInfo
  { id    :: UserId
  , name  :: UserName
  , email :: UserEmail
  }

derive instance eqUserInfo :: Eq UserInfo

data Sdk

newtype Scope = Scope String
derive newtype instance eqScope :: Eq Scope
derive instance newtypeScope :: Newtype Scope _

newtype LoginOptions = LoginOptions
  { scopes :: Array Scope
  }
instance encodeLoginOptions :: EncodeJson LoginOptions where
  encodeJson (LoginOptions { scopes: sx }) =
    encodeJson $ SM.fromFoldable [Tuple "scope" (encodeJson $ joinWith "," (map unwrap sx))]

instance showSdk :: Show Sdk where
  show = const "[Facebook SDK]"


readStatusInfo :: Foreign -> F StatusInfo
readStatusInfo value = do
  st <- value ! "status" >>= readStatus
  ar <- value ! "authResponse" >>= readNullOrUndefined >>= traverse readAuthResponse
  pure $ StatusInfo { status: st, authResponse: ar}
  where
    readStatus :: Foreign -> F Status
    readStatus status = do
      str <- readString status
      case str of
        "connected"      -> pure Connected
        "not_authorized" -> pure NotAuthorized
        _        ->         pure Unknown
    readAuthResponse :: Foreign -> F AuthResponse
    readAuthResponse authResponse = do
      at <- authResponse ! "accessToken" >>= readString <#> AccessToken
      ei <- authResponse ! "expiresIn" >>= readInt
      sr <- authResponse ! "signedRequest" >>= readString
      id <- authResponse ! "userID" >>= readString <#> UserId
      pure $ AuthResponse { accessToken: at
                          , expiresIn: ei
                          , signedRequest: sr
                          , userId: id
                          }

type SMap = SM.Object String

readSMap :: Foreign -> F SMap
readSMap value = do
  ks <- keys value
  vs <- traverse (\key -> value ! key >>= readString) ks
  pure $ SM.fromFoldable (zip ks vs)

-- | Initialize Facebook SDK
init :: Config -> Aff Sdk
init config = Aff.makeAff \callback -> do
  Exception.catchException
    (callback <<< Left)
    (_init (callback <<< Right) config)
  pure Aff.nonCanceler

-- | Retrieve a Facebook Login status
loginStatus :: Sdk -> Aff StatusInfo
loginStatus = returnStatusInfo _loginStatus

-- | Login user
login :: LoginOptions -> Sdk -> Aff StatusInfo
login opts = returnStatusInfo $ _login (unsafeToForeign $ encodeJson opts)

-- | Logout user
logout :: Sdk -> Aff StatusInfo
logout = returnStatusInfo _logout

userInfo :: AccessToken -> Sdk -> Aff UserInfo
userInfo token sdk = me [Id, Name, Email] token sdk >>= \m ->
  either missingField pure $ do
    id <- note "id" (UserId <$> M.lookup Id m)
    name <- note "name" (UserName <$> M.lookup Name m)
    email <- note "email" (UserEmail <$> M.lookup Email m)
    pure $ UserInfo { id, name, email }
  where missingField s = throwError $ error ("Can't build Facebook user info because of missing user " <> s)

-- | Get information about logged user
-- | https://developers.facebook.com/docs/graph-api/overview#step3
me :: Array Field -> AccessToken -> Sdk -> Aff (M.Map Field String)
me fields token sdk = transFields =<< api sdk token Get "/me" (requestFields fields)
  where transFields m = either (throwError <<< error) pure $ foldWithIndexM transField M.empty m
        transField key map val = (\k v -> M.insert k v map) <$> readField key <*> Right val
        requestFields fs = SM.insert "fields" (joinFields fs) SM.empty
        joinFields fs = joinWith "," (show >>> toLower <$> fs)

type ApiPath = String
type ApiParams = SMap
type ApiPathF = Foreign
type ApiParamsF = Foreign
type ApiMethodF = Foreign

data ApiMethod = Get | Post | Delete
derive instance eqApiMethod :: Eq ApiMethod
derive instance genericApiMethod :: Generic ApiMethod _
instance showApiMethod :: Show ApiMethod where show = genericShow

instance encodeApiMethod :: EncodeJson ApiMethod where
  encodeJson Get = encodeJson "get"
  encodeJson Post = encodeJson "post"
  encodeJson Delete = encodeJson "delete"

api :: Sdk
    -> AccessToken
    -> ApiMethod
    -> ApiPath
    -> ApiParams
    -> Aff SMap
api sdk (AccessToken token) method path params = do
  let path' = unsafeToForeign $ encodeJson path
  let method' = unsafeToForeign $ encodeJson method
  let params' = unsafeToForeign $ encodeJson $ SM.insert "access_token" token params
  value <- Aff.makeAff \callback -> do
    Exception.catchException
      (callback <<< Left)
      (runFn5 _api sdk path' method' params' (callback <<< Right))
    pure Aff.nonCanceler
  let prefix = "Facebook graph api call (" <> (show method) <> " "
                                           <> (show path)   <> ") error"
  either (handleForeignErrors prefix) pure $ runExcept (readSMap value)

returnStatusInfo :: (Sdk -> (Foreign -> Effect Unit) -> Effect Unit)
                 -> Sdk
                 -> Aff StatusInfo
returnStatusInfo f sdk = do
  value <- Aff.makeAff \callback -> do
    Exception.catchException
      (callback <<< Left)
      (f sdk (callback <<< Right))
    pure Aff.nonCanceler
  either (handleForeignErrors "Facebook status info") pure $
    runExcept (readStatusInfo value)

-- | String is an error message prefix
handleForeignErrors :: forall a. String -> MultipleErrors -> Aff a
handleForeignErrors prefix errors =
  let message = prefix <> ": " <> intercalate "; " (map show errors)
  in throwError $ error message

-- | https://developers.facebook.com/docs/javascript/reference/.init/v2.10
foreign import _init :: (Sdk -> Effect Unit) -> Config -> Effect Unit

-- | https://developers.facebook.com/docs/reference/javascript/FB.login
foreign import _login :: Foreign -> Sdk -> (Foreign -> Effect Unit) -> Effect Unit

-- | https://developers.facebook.com/docs/reference/javascript/FB.logout
foreign import _logout :: Sdk -> (Foreign -> Effect Unit) -> Effect Unit

-- | https://developers.facebook.com/docs/reference/javascript/FB.getLoginStatus
foreign import _loginStatus :: Sdk -> (Foreign -> Effect Unit) -> Effect Unit

-- | https://developers.facebook.com/docs/javascript/reference/FB.api/
foreign import _api :: Fn5 Sdk ApiPathF ApiMethodF ApiParamsF (Foreign -> Effect Unit) (Effect Unit)
