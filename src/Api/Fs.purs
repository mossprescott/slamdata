module Api.Fs where

import Api.Common (succeeded, getResponse)
import Control.Apply ((*>))
import Control.Monad.Aff (Aff())
import Control.Monad.Eff.Exception (error)
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core (Json())
import Data.Argonaut.Decode (decodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (head, findIndex)
import Data.Either (Either(..), either)
import Data.Foreign (Foreign())
import Data.Foreign.Class (readProp, read, IsForeign)
import Data.Maybe
import Data.Path.Pathy
import Data.String (split, length, take, joinWith)
import Data.These (These(..), theseLeft, theseRight)
import Model.Path
import Network.HTTP.Affjax (Affjax(), AJAX(), affjax, get, put_, delete_, defaultRequest)
import Network.HTTP.Affjax.Response (Respondable, ResponseType(JSONResponse))
import Network.HTTP.Method (Method(MOVE))
import Network.HTTP.RequestHeader (RequestHeader(..))
import Optic.Core ((..), (.~), (^.))

import qualified Data.Maybe.Unsafe as U
import qualified Model.Notebook.Domain as N
import qualified Model.Resource as R

newtype Listing = Listing [R.Resource]

runListing :: Listing -> [R.Resource]
runListing (Listing rs) = rs

instance listingIsForeign :: IsForeign Listing where
  read f = Listing <$> readProp "children" f

instance listingRespondable :: Respondable Listing where
  responseType = JSONResponse
  fromResponse = read

children :: forall e. R.Resource -> Aff (ajax :: AJAX | e) [R.Resource]
children r = do
  cs <- children' $ R.resourcePath r
  pure $ (R._root .~ (either (const rootDir) id $ R.getPath r)) <$> cs

children' :: forall e. String -> Aff (ajax :: AJAX | e) [R.Resource]
children' str = runListing <$> (getResponse msg $ listing str)
  where
  msg = "error getting resource children"

listing :: forall e. String -> Affjax e Listing
listing str = get (Config.metadataUrl <> str)

makeFile :: forall e. AnyPath -> String -> Aff (ajax :: AJAX | e) Unit
makeFile ap content =
  getResponse msg $ either err go isJson
  where
  resource :: R.Resource
  resource = R.newFile # R._path .~ ap

  msg :: String
  msg = "error while creating file"

  err :: _ -> Aff _ _
  err _ = throwError $ error "file has incorrect format"

  firstLine :: Maybe String
  firstLine = head $ split "\n" content

  isJson :: Either _ _
  isJson = maybe (Left "empty file") Right firstLine >>= jsonParser

  go :: _ -> Aff _ _
  go _ = put_ (Config.dataUrl <> R.resourcePath resource) content

loadNotebook :: forall e. R.Resource -> Aff (ajax :: AJAX | e) N.Notebook
loadNotebook res = do
  val <- getResponse "error loading notebook" $ get (Config.dataUrl <> R.resourcePath res <> "/index")
  case decodeJson (foreignToJson val) of
    Left err -> throwError (error err)
    Right notebook ->
      let name = dropNotebookExt (R.resourceName res)
      in pure (notebook # (N._path .~ R.resourceDir res)
                       .. (N._name .~ That name))

-- TODO: Not this. either add to Argonaut, or make a Respondable Json instance (requires "argonaut core" - https://github.com/slamdata/purescript-affjax/issues/16#issuecomment-93565447)
foreign import foreignToJson
  """
  function foreignToJson(x) {
    return x;
  }
  """ :: Foreign -> Json

-- | Saves (creating or updating) a notebook. If the notebook's `name` value is
-- | a `This` value the name will be used as a basis for generating a new
-- | notebook. If the `name` value is a `Both` value the notebook will be saved
-- | and then moved. If the name is a `That` the notebook will be saved.
saveNotebook :: forall e. N.Notebook -> Aff (ajax :: AJAX | e) N.Notebook
saveNotebook notebook = case notebook ^. N._name of
  That name -> save name *> pure notebook
  This name -> do
    let baseName = (U.fromJust $ theseLeft (notebook ^. N._name)) ++ "." ++ Config.notebookExtension
    name <- getNewName (notebook ^. N._path) baseName
    save name
    pure (notebook # N._name .~ That (dropNotebookExt name))
  Both newName oldName | newName /= oldName -> do
    save oldName
    alreadyExists <- exists (newName ++ "." ++ Config.notebookExtension) (notebook ^. N._path)
    if alreadyExists
      then throwError (error "A file already exists with the specified name")
      else
        let oldPath = Right $ (notebook ^. N._path) </> dir oldName <./> Config.notebookExtension
            newPath = Right $ (notebook ^. N._path) </> dir newName <./> Config.notebookExtension
        in move oldPath newPath *> pure (notebook # N._name .~ That newName)
  where
  save name =
    let notebookPath = (notebook ^. N._path) </> dir name <./> Config.notebookExtension </> file "index"
    in getResponse "error while saving notebook" $ put_ (Config.dataUrl <> printPath notebookPath) notebook

-- | Generates a new resource name based on a directory path and a name for the
-- | resource. If the name already exists in the path a number is appended to
-- | the end of the name.
getNewName :: forall e. DirPath -> String -> Aff (ajax :: AJAX | e) String
getNewName parent name = do
  items <- children' (printPath parent)
  pure if exists' name items then getNewName' items 1 else name
  where
  getNewName' items i =
    case split "." name of
      [] -> ""
      body:suffixes ->
        let newName = joinWith "." $ (body ++ " " ++ show i):suffixes
        in if exists' newName items then getNewName' items (i + 1) else newName

exists :: forall e. String -> DirPath -> Aff (ajax :: AJAX | e) Boolean
exists name parent = exists' name <$> children' (printPath parent)

exists' :: forall e. String -> [R.Resource] -> Boolean
exists' name items = findIndex (\r -> r ^. R._name == name) items /= -1

delete :: forall e. R.Resource -> Aff (ajax :: AJAX | e) Unit
delete resource =
  getResponse msg $ delete_ (Config.dataUrl <> R.resourcePath resource)
  where msg = "can not delete"

move :: forall a e. AnyPath -> AnyPath -> Aff (ajax :: AJAX | e) AnyPath
move src tgt = do
  result <- affjax $ defaultRequest
    { method = MOVE
    , headers = [RequestHeader "Destination" $ either printPath printPath tgt]
    , url = Config.dataUrl <> either printPath printPath src
    }
  if succeeded result.status
     then pure tgt
     else throwError (error result.response)
