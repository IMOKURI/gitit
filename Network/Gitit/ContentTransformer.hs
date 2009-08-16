{-
Copyright (C) 2009 John MacFarlane <jgm@berkeley.edu>,
Anton van Straaten <anton@appsolutions.com>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- Functions for content conversion.
-}

module Network.Gitit.ContentTransformer
  (
  -- ContentTransformer runners
    runPageTransformer
  , runFileTransformer
  -- Gitit responders
  , showRawPage
  , showFileAsText
  , showPage
  , exportPage
  , showHighlightedSource
  , showFile
  , preview
  , applyPreCommitPlugins
  -- Cache support for transformers
  , cacheHtml
  , cachedHtml
  -- Content retrieval combinators
  , rawContents
  -- Response-generating combinators
  , textResponse
  , mimeFileResponse
  , mimeResponse
  , exportPandoc
  , applyWikiTemplate
  -- Content-type transformation combinators
  , pageToWikiPandocPage
  , pageToWikiPandoc
  , pageToPandoc
  , pandocToHtml
  , highlightSource
  -- Content or context augmentation combinators
  , applyPageTransforms
  , wikiDivify
  , addPageTitleToPandoc
  , addMathSupport
  , addScripts
  -- ContentTransformer context API
  , getFileName
  , getPageName
  , getLayout
  , getParams
  , getCacheable
  -- Pandoc and wiki content conversion support
  , inlinesToURL
  , inlinesToString
  )
where

import Prelude hiding (catch)
import Network.Gitit.Server
import Network.Gitit.Framework
import Network.Gitit.State
import Network.Gitit.Types
import Network.Gitit.Layout
import Network.Gitit.Export (exportFormats)
import Network.Gitit.Page (stringToPage)
import Network.Gitit.Cache (lookupCache, cacheContents)
import qualified Data.FileStore as FS
import Data.Maybe (mapMaybe)
import Text.Pandoc
import Text.Pandoc.Shared (HTMLMathMethod(..))
import Text.XHtml hiding ( (</>), dir, method, password, rev )
import Text.Highlighting.Kate
import Data.Maybe (isNothing)
import Codec.Binary.UTF8.String (encodeString)
import System.FilePath
import Control.Monad.State
import Control.Exception (throwIO, catch)
import Network.HTTP (urlEncodeVars)
import Network.URI (isAllowedInURI, escapeURIString)
import qualified Data.ByteString as S (concat) 
import qualified Data.ByteString.Lazy as L (toChunks, fromChunks)

--
-- ContentTransformer runners
--

runPageTransformer :: ToMessage a
                   => ContentTransformer a
                   -> GititServerPart a 
runPageTransformer xform = withData $ \params -> do
  page <- getPage
  cfg <- getConfig
  evalStateT xform  Context{ ctxFile = pathForPage page
                           , ctxLayout = defaultPageLayout{
                                             pgPageName = page
                                           , pgTitle = page
                                           , pgPrintable = pPrintable params
                                           , pgMessages = pMessages params
                                           , pgRevision = pRevision params
                                           , pgLinkToFeed = useFeed cfg }
                           , ctxCacheable = True
                           , ctxTOC = tableOfContents cfg
                           , ctxBirdTracks = showLHSBirdTracks cfg
                           , ctxCategories = [] }

runFileTransformer :: ToMessage a
                   => ContentTransformer a
                   -> GititServerPart a
runFileTransformer xform = withData $ \params -> do
  file <- getPage
  cfg <- getConfig
  evalStateT xform  Context{ ctxFile = file
                           , ctxLayout = defaultPageLayout{
                                             pgPageName = file
                                           , pgTitle = file
                                           , pgPrintable = pPrintable params
                                           , pgMessages = pMessages params
                                           , pgRevision = pRevision params
                                           , pgLinkToFeed = useFeed cfg }
                           , ctxCacheable = True
                           , ctxTOC = tableOfContents cfg
                           , ctxBirdTracks = showLHSBirdTracks cfg
                           , ctxCategories = [] }

--
-- Gitit responders
--

showRawPage :: Handler
showRawPage = runPageTransformer rawTextResponse

showFileAsText :: Handler
showFileAsText = runFileTransformer rawTextResponse

showPage :: Handler
showPage = runPageTransformer htmlViaPandoc

exportPage :: Handler 
exportPage = runPageTransformer exportViaPandoc

showHighlightedSource :: Handler
showHighlightedSource = runFileTransformer highlightRawSource

showFile :: Handler
showFile = runFileTransformer (rawContents >>= mimeFileResponse)

preview :: Handler
preview = runPageTransformer $
          liftM (filter (/= '\r') . pRaw) getParams >>=
          contentsToPage >>=
          pageToWikiPandoc >>=
          pandocToHtml >>=
          return . toResponse . renderHtmlFragment

applyPreCommitPlugins :: String -> GititServerPart String
applyPreCommitPlugins rawtext =
  runPageTransformer (applyPreCommitTransforms rawtext)

--
-- Top level, composed transformers
--

rawTextResponse :: ContentTransformer Response
rawTextResponse = rawContents >>= textResponse

exportViaPandoc :: ContentTransformer Response
exportViaPandoc = rawContents >>= maybe mzero return >>= contentsToPage >>= pageToWikiPandocPage >>= exportPandoc

htmlViaPandoc :: ContentTransformer Response
htmlViaPandoc = cachedHtml `mplus`
                  (rawContents >>=
                   maybe mzero return >>=
                   contentsToPage >>=
                   pageToWikiPandoc >>=
                   addMathSupport >>=
                   pandocToHtml >>=
                   wikiDivify >>=
                   applyWikiTemplate >>=
                   cacheHtml)

highlightRawSource :: ContentTransformer Response
highlightRawSource =
  cachedHtml `mplus`
    (updateLayout (\l -> l { pgTabs = [ViewTab,HistoryTab] }) >> 
     rawContents >>=
     highlightSource >>=
     applyWikiTemplate >>=
     cacheHtml)

--
-- Cache support for transformers
--

cacheHtml :: Response -> ContentTransformer Response 
cacheHtml resp = do
  params <- getParams
  file <- getFileName
  cacheable <- getCacheable
  when (isNothing (pRevision params) && not (pPrintable params) && cacheable) $
    lift $ cacheContents file $ S.concat $ L.toChunks $ rsBody resp 
  return resp 

-- | Returns cached page if available, otherwise mzero.
cachedHtml :: ContentTransformer Response
cachedHtml = do
  file <- getFileName
  params <- getParams
  if not (pPrintable params) && isNothing (pRevision params)
     then do mbCached <- lift $ lookupCache file
             let emptyResponse = setContentType "text/html; charset=utf-8" . toResponse $ ()
             maybe mzero (\(_modtime, contents) -> lift . ok $ emptyResponse{rsBody = L.fromChunks [contents]}) mbCached
     else mzero

--
-- Content retrieval combinators
--

-- | Returns raw file contents
rawContents :: ContentTransformer (Maybe String)
rawContents = do
  params <- getParams
  file <- getFileName
  fs <- lift getFileStore
  let rev = pRevision params
  liftIO $ catch (liftM Just $ FS.retrieve fs file rev)
                 (\e -> if e == FS.NotFound then return Nothing else throwIO e)

--
-- Response-generating combinators
--

textResponse :: Maybe String -> ContentTransformer Response
textResponse Nothing  = mzero  -- fail quietly if file not found
textResponse (Just c) = mimeResponse c "text/plain; charset=utf-8"

mimeFileResponse :: Maybe String -> ContentTransformer Response
mimeFileResponse Nothing = error "Unable to retrieve file contents."
mimeFileResponse (Just c) =
  mimeResponse c =<< lift . getMimeTypeForExtension . takeExtension =<< getFileName

mimeResponse :: Monad m => String -> String -> m Response
mimeResponse c mimeType =
  return . setContentType mimeType . toResponse $ c

-- | Exports Pandoc as Response using format specified in Params
exportPandoc :: Pandoc -> ContentTransformer Response
exportPandoc doc = do
  params <- getParams
  page <- getPageName
  let format = pFormat params
  case lookup format exportFormats of
       Nothing     -> error $ "Unknown export format: " ++ format
       Just writer -> lift (writer page doc)

applyWikiTemplate :: Html -> ContentTransformer Response
applyWikiTemplate c = do
  Context { ctxLayout = layout } <- get
  lift $ formattedPage layout c

--
-- Content-type transformation combinators
--

-- | Converts Page to Pandoc, applies page transforms, and adds page
-- title to Pandoc meta info
pageToWikiPandocPage :: Page -> ContentTransformer Pandoc
pageToWikiPandocPage page' =
  pageToWikiPandoc page' >>= addPageTitleToPandoc (pageTitle page')

-- | Converts source text to Pandoc and applies page transforms
pageToWikiPandoc :: Page -> ContentTransformer Pandoc
pageToWikiPandoc = applyPreParseTransforms >=>
                     pageToPandoc >=> applyPageTransforms

-- | Converts source text to Pandoc using default page type
pageToPandoc :: Page -> ContentTransformer Pandoc
pageToPandoc page' = do
  modifyContext $ \ctx -> ctx{ ctxTOC = pageTOC page'
                             , ctxCategories = pageCategories page' }
  return $ readerFor (pageFormat page') (pageLHS page') (pageText page')

-- | Converts contents of page file to Page object
contentsToPage :: String -> ContentTransformer Page
contentsToPage s = do
  cfg <- lift getConfig
  pn <- getPageName
  return $ stringToPage cfg pn s

-- | Converts pandoc document to HTML.
pandocToHtml :: Pandoc -> ContentTransformer Html
pandocToHtml pandocContents = do
  base' <- lift getWikiBase
  toc <- liftM ctxTOC get
  bird <- liftM ctxBirdTracks get
  return $ writeHtml defaultWriterOptions{
                        writerStandalone = False
                      , writerHTMLMathMethod = JsMath
                               (Just $ base' ++ "/_static/js/jsMath/easy/load.js")
                      , writerTableOfContents = toc
                      , writerLiterateHaskell = bird
                      } pandocContents

highlightSource :: Maybe String -> ContentTransformer Html
highlightSource Nothing = mzero
highlightSource (Just source) = do
  file <- getFileName
  let lang' = head $ languagesByExtension $ takeExtension file
  case highlightAs lang' (filter (/='\r') source) of
       Left _       -> mzero
       Right res    -> return $ formatAsXHtml [OptNumberLines] lang' $! res

--
-- Plugin combinators
--

getPageTransforms :: ContentTransformer [Pandoc -> PluginM Pandoc]
getPageTransforms = liftM (mapMaybe pageTransform) $ queryGititState plugins
  where pageTransform (PageTransform x) = Just x
        pageTransform _                 = Nothing

getPreParseTransforms :: ContentTransformer [String -> PluginM String]
getPreParseTransforms = liftM (mapMaybe preParseTransform) $
                          queryGititState plugins
  where preParseTransform (PreParseTransform x) = Just x
        preParseTransform _                     = Nothing

getPreCommitTransforms :: ContentTransformer [String -> PluginM String]
getPreCommitTransforms = liftM (mapMaybe preCommitTransform) $
                          queryGititState plugins
  where preCommitTransform (PreCommitTransform x) = Just x
        preCommitTransform _                      = Nothing

applyTransform :: a -> (a -> PluginM a) -> ContentTransformer a
applyTransform inp transform = do
  context <- get
  conf <- lift getConfig
  user <- lift getLoggedInUser
  fs <- lift getFileStore
  req <- lift askRq
  let pluginData = PluginData{ pluginConfig = conf
                             , pluginUser = user
                             , pluginRequest = req
                             , pluginFileStore = fs }
  (result', context') <- liftIO $ runPluginM (transform inp) pluginData context
  put context'
  return result'

applyPageTransforms :: Pandoc -> ContentTransformer Pandoc 
applyPageTransforms c = liftM (wikiLinksTransform : ) getPageTransforms >>=
                        foldM applyTransform c

applyPreParseTransforms :: Page -> ContentTransformer Page
applyPreParseTransforms page' = getPreParseTransforms >>= foldM applyTransform (pageText page') >>=
                                (\t -> return page'{ pageText = t })

applyPreCommitTransforms :: String -> ContentTransformer String
applyPreCommitTransforms c = getPreCommitTransforms >>= foldM applyTransform c

--
-- Content or context augmentation combinators
--

wikiDivify :: Html -> ContentTransformer Html
wikiDivify c = do
  params <- getParams
  categories <- liftM ctxCategories get
  base' <- lift getWikiBase
  let categoryLink ctg = li (anchor ! [href $ base' ++ "/_category/" ++ ctg] << ctg)
  let htmlCategories = if null categories
                          then noHtml
                          else thediv ! [identifier "categoryList"] << ulist << map categoryLink categories
  let dblClickJs = "window.location = window.location + '?edit" ++
                   case pRevision params of
                        Nothing   -> "';"
                        Just r    -> ("&" ++ urlEncodeVars [("revision", r),
                              ("logMsg", "Revert to " ++ r)] ++ "';")
  return $ thediv ! [identifier "wikipage",
                     strAttr "onDblClick" dblClickJs] << [c, htmlCategories]

addPageTitleToPandoc :: String -> Pandoc -> ContentTransformer Pandoc
addPageTitleToPandoc title' (Pandoc _ blocks) = do
  updateLayout $ \layout -> layout{ pgTitle = title' }
  return $ if null title'
              then Pandoc (Meta [] [] []) blocks
              else Pandoc (Meta [Str title'] [] []) blocks

addMathSupport :: a -> ContentTransformer a
addMathSupport c = do
  conf <- lift getConfig
  updateLayout $ \l -> addScripts l ["jsMath/easy/load.js" | jsMath conf]
  return c

addScripts :: PageLayout -> [String] -> PageLayout
addScripts layout scriptPaths =
  layout{ pgScripts = scriptPaths ++ pgScripts layout }

--
-- ContentTransformer context API
--

getParams :: ContentTransformer Params
getParams = lift (withData return)

getFileName :: ContentTransformer FilePath
getFileName = liftM ctxFile get

getPageName :: ContentTransformer String
getPageName = liftM (pgPageName . ctxLayout) get

getLayout :: ContentTransformer PageLayout
getLayout = liftM ctxLayout get

getCacheable :: ContentTransformer Bool
getCacheable = liftM ctxCacheable get

-- | Updates the layout with the result of applying f to the current layout
updateLayout :: (PageLayout -> PageLayout) -> ContentTransformer ()
updateLayout f = do
  ctx <- get
  let l = ctxLayout ctx
  put ctx { ctxLayout = f l }

--
-- Pandoc and wiki content conversion support
--

readerFor :: PageType -> Bool -> (String -> Pandoc)
readerFor pt lhs =
  let defPS = defaultParserState{ stateSanitizeHTML = True
                                , stateSmart = True
                                , stateLiterateHaskell = lhs }
  in case pt of
       RST      -> readRST defPS
       Markdown -> readMarkdown defPS
       LaTeX    -> readLaTeX defPS
       HTML     -> readHtml defPS

wikiLinksTransform :: Pandoc -> PluginM Pandoc
wikiLinksTransform = return . processWith convertWikiLinks

-- | Convert links with no URL to wikilinks.
convertWikiLinks :: Inline -> Inline
convertWikiLinks (Link ref ("", "")) =
  Link ref (inlinesToURL ref, "Go to wiki page")
convertWikiLinks x = x

inlinesToURL :: [Inline] -> String
inlinesToURL = escapeURIString isAllowedInURI  . encodeString . inlinesToString

-- | Convert a list of inlines into a string.
inlinesToString :: [Inline] -> String
inlinesToString = concatMap go
  where go x = case x of
               Str s                   -> s
               Emph xs                 -> concatMap go xs
               Strong xs               -> concatMap go xs
               Strikeout xs            -> concatMap go xs
               Superscript xs          -> concatMap go xs
               Subscript xs            -> concatMap go xs
               SmallCaps xs            -> concatMap go xs
               Quoted DoubleQuote xs   -> '"' : (concatMap go xs ++ "\"")
               Quoted SingleQuote xs   -> '\'' : (concatMap go xs ++ "'")
               Cite _ xs               -> concatMap go xs
               Code s                  -> s
               Space                   -> " "
               EmDash                  -> "---"
               EnDash                  -> "--"
               Apostrophe              -> "'"
               Ellipses                -> "..."
               LineBreak               -> " "
               Math DisplayMath s      -> "$$" ++ s ++ "$$"
               Math InlineMath s       -> "$" ++ s ++ "$"
               TeX s                   -> s
               HtmlInline _            -> ""
               Link xs _               -> concatMap go xs
               Image xs _              -> concatMap go xs
               Note _                  -> ""

