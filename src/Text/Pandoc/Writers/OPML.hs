{-# LANGUAGE CPP #-}
{-
Copyright (C) 2013-2015 John MacFarlane <jgm@berkeley.edu>

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

{- |
   Module      : Text.Pandoc.Writers.OPML
   Copyright   : Copyright (C) 2013-2015 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to OPML XML.
-}
module Text.Pandoc.Writers.OPML ( writeOPML) where
import Text.Pandoc.Definition
import Text.Pandoc.XML
import Text.Pandoc.Writers.Shared
import Text.Pandoc.Shared
import Text.Pandoc.Options
import Text.Pandoc.Templates (renderTemplate')
import Text.Pandoc.Writers.HTML (writeHtmlString)
import Text.Pandoc.Writers.Markdown (writeMarkdown)
import Text.Pandoc.Pretty
import Text.Pandoc.Compat.Time
import qualified Text.Pandoc.Builder as B
import Text.Pandoc.Class (PandocMonad)

-- | Convert Pandoc document to string in OPML format.
writeOPML :: PandocMonad m => WriterOptions -> Pandoc -> m String
writeOPML opts (Pandoc meta blocks) = do
  let elements = hierarchicalize blocks
      colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
      meta' = B.setMeta "date" (B.str $ convertDate $ docDate meta) meta
  metadata <- metaToJSON opts
              (writeMarkdown def . Pandoc nullMeta)
              (\ils -> trimr <$> (writeMarkdown def $ Pandoc nullMeta [Plain ils]))
              meta'
  main <- (render colwidth . vcat) <$> (mapM (elementToOPML opts) elements)
  let context = defField "body" main metadata
  return $ if writerStandalone opts
           then renderTemplate' (writerTemplate opts) context
           else main

writeHtmlInlines :: PandocMonad m => [Inline] -> m String
writeHtmlInlines ils =
  trim <$> (writeHtmlString def $ Pandoc nullMeta [Plain ils])

-- date format: RFC 822: Thu, 14 Jul 2005 23:41:05 GMT
showDateTimeRFC822 :: UTCTime -> String
showDateTimeRFC822 = formatTime defaultTimeLocale "%a, %d %b %Y %X %Z"

convertDate :: [Inline] -> String
convertDate ils = maybe "" showDateTimeRFC822 $
#if MIN_VERSION_time(1,5,0)
  parseTimeM True
#else
  parseTime
#endif
  defaultTimeLocale "%F" =<< (normalizeDate $ stringify ils)

-- | Convert an Element to OPML.
elementToOPML :: PandocMonad m => WriterOptions -> Element -> m Doc
elementToOPML _ (Blk _) = return empty
elementToOPML opts (Sec _ _num _ title elements) = do
  let isBlk (Blk _) = True
      isBlk _     = False
      fromBlk (Blk x) = x
      fromBlk _ = error "fromBlk called on non-block"
      (blocks, rest) = span isBlk elements
  htmlIls <- writeHtmlInlines title
  md <- if null blocks
        then return []
        else writeMarkdown def $ Pandoc nullMeta $ map fromBlk blocks
  let attrs = [("text", htmlIls)] ++ [("_note", md)]
  o <- mapM (elementToOPML opts) rest
  return $ inTags True "outline" attrs $ vcat o
