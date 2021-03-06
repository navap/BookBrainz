{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module BookBrainz.Search where

import           Control.Applicative

import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Data.Aeson             ((.=), ToJSON(..), FromJSON(..), object
                                        ,(.:), Value(..))
import qualified Data.Text              as T
import           Database.HDBC          (toSql, fromSql)
import           Data.Aeson.Types       (typeMismatch)
import           Data.Copointed         (copoint)
import           Data.Map               (union)
import qualified Search.ElasticSearch   as ES
import           Search.ElasticSearch   (Document(..), DocumentType(..)
                                        ,localServer, indexDocument, Index)

import           BookBrainz.Types       as BB

--------------------------------------------------------------------------------
-- | The types of searches that are possible.
data SearchType = Book

--------------------------------------------------------------------------------
-- | A book is searchable by it's name, and all roles.
data SearchableBook = SearchableBook
    { bookResult  :: LoadedCoreEntity BB.Book
    , bookRoles :: [(LoadedEntity BB.Role, LoadedCoreEntity BB.Person)]
    }

instance Document SearchableBook where
  documentKey = T.pack . show . bbid . bookResult
  documentType = DocumentType "book"

instance ToJSON SearchableBook where
  toJSON (SearchableBook book roles) = toJSON book
                                       `unionObject`
                                       object [ "roles" .= toJSON roles ]

instance ToJSON Book where
  toJSON book = object [ "name" .= bookName book ]

instance ToJSON Person where
  toJSON person = object [ "name" .= personName person ]

instance ToJSON (LoadedEntity Role, LoadedCoreEntity Person) where
  toJSON (role, person) = object [ "role" .= role
                                 , "person" .= person
                                 ]

instance FromJSON SearchableBook where
  parseJSON json@(Object o) =
      SearchableBook <$> parseJSON json
                     <*> (o .: "roles" >>= mapM parseRole)
    where parseRole r = (,) <$> r .: "role"
                            <*> r .: "person"
  parseJSON v = typeMismatch "SearchableBook" v

instance FromJSON BB.Book where
  parseJSON (Object b) = BB.Book <$> b .: "name"
  parseJSON v = typeMismatch "Book" v

instance ToJSON BB.Role where
  toJSON role = object [ "role" .= roleName role ]

instance FromJSON BB.Role where
  parseJSON (String r) = return $ BB.Role r
  parseJSON v = typeMismatch "Role" v

instance FromJSON BB.Person where
  parseJSON (Object b) = BB.Person <$> b .: "name"
  parseJSON v = typeMismatch "Person" v

index' :: (Document d, MonadIO m) => SearchType -> d -> m ()
index' t d = liftIO $ indexDocument localServer (typeToIndex t) d

--------------------------------------------------------------------------------
-- | Given a book and accompanying metadata, index the book.
indexBook :: (MonadIO m)
          => LoadedCoreEntity BB.Book
          -> [(LoadedEntity BB.Role, LoadedCoreEntity BB.Person)]
          -> m ()
indexBook = (index' BookBrainz.Search.Book .) . SearchableBook

--------------------------------------------------------------------------------
-- | Search for books, given a query.
searchBooks :: (MonadIO m) => T.Text -> m (ES.SearchResults SearchableBook)
searchBooks = search BookBrainz.Search.Book

--------------------------------------------------------------------------------
-- | Run a search for a given type of entity.
search :: (Document d, MonadIO m)
       => SearchType  -- ^ The type of entities to search for
       -> T.Text
       -> m (ES.SearchResults d)
search t = liftIO . ES.search localServer (typeToIndex t) 0

unionObject :: Value -> Value -> Value
unionObject (Object a) (Object b) = Object (a `union` b)
unionObject _ _ = error "unionObject can only be called with 2 Objects"

instance ToJSON (BBID a) where
  toJSON = toJSON . show

instance FromJSON (BBID a) where
  parseJSON (String s) =
    maybe (fail "Couldnt parse UUID") return (parseBbid $ T.unpack s)
  parseJSON v = typeMismatch "UUID" v

instance FromJSON entity => FromJSON (LoadedCoreEntity entity) where
  parseJSON json@(Object o) = CoreEntity <$> o .: "bbid"
                                         <*> o .: "_revision"
                                         <*> o .: "_tree"
                                         <*> parseJSON json
                                         <*> o .: "_concept"
  parseJSON v = typeMismatch "LoadedCoreEntity" v

instance ToJSON ent => ToJSON (LoadedCoreEntity ent) where
  toJSON ent = object [ "bbid" .= bbid ent
                       , "_tree" .= coreEntityTree ent
                       , "_revision" .= coreEntityRevision ent
                       , "_concept" .= coreEntityConcept ent
                       ]
               `unionObject`
               toJSON (copoint ent)

instance ToJSON a => ToJSON (LoadedEntity a) where
  toJSON loaded = object [ "_ref" .= entityRef loaded ]
                  `unionObject`
                  toJSON (copoint loaded)

instance (FromJSON entity) => FromJSON (LoadedEntity entity) where
  parseJSON json@(Object o) = Entity <$> parseJSON json
                                     <*> o .: "_ref"
  parseJSON v = typeMismatch "LoadedEntity" v

instance ToJSON (Ref a) where
  toJSON ref = toJSON (fromSql $ rowKey ref :: String)

instance FromJSON (Ref a) where
  parseJSON (String s) = return (Ref $ toSql $ T.unpack s)
  parseJSON v = typeMismatch "Ref" v

typeToIndex :: SearchType -> Index
typeToIndex BookBrainz.Search.Book = "book"
