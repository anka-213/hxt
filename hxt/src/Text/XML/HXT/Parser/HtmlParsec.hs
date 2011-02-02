-- ------------------------------------------------------------

{- |
   Module     : Text.XML.HXT.Parser.HtmlParsec
   Copyright  : Copyright (C) 2005 Uwe Schmidt
   License    : MIT

   Maintainer : Uwe Schmidt (uwe@fh-wedel.de)
   Stability  : stable
   Portability: portable

   This parser tries to interprete everything as HTML
   no errors are emitted during parsing. If something looks
   weired, warning messages are inserted in the document tree.

   All filter are pure XmlFilter,
   errror handling and IO is done in 'Text.XML.HXT.Parser.HtmlParser'
   or other modules

-}

-- ------------------------------------------------------------

module Text.XML.HXT.Parser.HtmlParsec
    ( parseHtmlText
    , parseHtmlDocument
    , parseHtmlContent
    , isEmptyHtmlTag
    , isInnerHtmlTagOf
    , closesHtmlTag
    , emptyHtmlTags
    )

where

import Data.Char                                ( toLower
                                                , toUpper
                                                )
import Data.Char.Properties.XMLCharProps        ( isXmlChar
                                                )
import Data.Maybe                               ( fromMaybe
                                                , fromJust
                                                )
import Text.ParserCombinators.Parsec            ( Parser
                                                , SourcePos
                                                , anyChar
                                                , between
                                                -- , char
                                                , eof
                                                , getPosition
                                                , many
                                                , many1
                                                , noneOf
                                                , option
                                                , parse
                                                , satisfy
                                                , string
                                                , try
                                                , (<|>)
                                                )

import Text.XML.HXT.DOM.Interface
import Text.XML.HXT.DOM.XmlNode                 ( mkText'
                                                , mkError'
                                                , mkCmt'
                                                , mkCharRef'
                                                , mkElement'
                                                , mkAttr'
                                                , mkDTDElem'
                                                , isEntityRef
                                                , getEntityRef
                                                )
import Text.XML.HXT.Parser.XmlTokenParser       ( allBut
                                                , amp
                                                , dq
                                                , eq
                                                , gt
                                                , lt
                                                , name
                                                , pubidLiteral
                                                , skipS
                                                , skipS0
                                                , sq
                                                , systemLiteral
                                                , checkString
                                                , singleCharsT
                                                , referenceT
                                                )
import Text.XML.HXT.Parser.XmlParsec            ( cDSect
                                                -- , charData'
                                                , misc
                                                , parseXmlText
                                                , pI
                                                , xMLDecl'
                                                )
import Text.XML.HXT.Parser.XmlCharParser        ( xmlChar
                                                )
import Text.XML.HXT.Parser.XhtmlEntities        ( xhtmlEntities
                                                )

-- ------------------------------------------------------------

parseHtmlText           :: String -> XmlTree -> XmlTrees
parseHtmlText loc t     = parseXmlText htmlDocument loc $ t

-- ------------------------------------------------------------

parseHtmlFromString     :: Parser XmlTrees -> String -> String -> XmlTrees
parseHtmlFromString parser loc
    = either ((:[]) . mkError' c_err . (++ "\n") . show) id . parse parser loc

parseHtmlDocument       :: String -> String -> XmlTrees
parseHtmlDocument       = parseHtmlFromString htmlDocument

parseHtmlContent        :: String -> XmlTrees
parseHtmlContent        = parseHtmlFromString htmlContent "text"

-- ------------------------------------------------------------

type Context    = (XmlTreeFl, OpenTags)

type XmlTreeFl  = XmlTrees -> XmlTrees

type OpenTags   = [(String, XmlTrees, XmlTreeFl)]

-- ------------------------------------------------------------

htmlDocument    :: Parser XmlTrees
htmlDocument
    = do
      pl <- htmlProlog
      el <- htmlContent
      eof
      return (pl ++ el)

htmlProlog      :: Parser XmlTrees
htmlProlog
    = do
      xml <- option []
             ( try xMLDecl'
               <|>
               ( do
                 pos <- getPosition
                 checkString "<?"
                 return $ [mkError' c_warn (show pos ++ " wrong XML declaration")]
               )
             )
      misc1   <- many misc
      dtdPart <- option []
                 ( try doctypedecl
                   <|>
                   ( do
                     pos <- getPosition
                     upperCaseString "<!DOCTYPE"
                     return $ [mkError' c_warn (show pos ++ " HTML DOCTYPE declaration ignored")]
                   )
                 )
      return (xml ++ misc1 ++ dtdPart)

doctypedecl     :: Parser XmlTrees
doctypedecl
    = between (upperCaseString "<!DOCTYPE") gt
      ( do
        skipS
        n <- name
        exId <- ( do
                  skipS
                  option [] externalID
                )
        skipS0
        return [mkDTDElem' DOCTYPE ((a_name, n) : exId) []]
      )

externalID      :: Parser Attributes
externalID
    = do
      upperCaseString k_public
      skipS
      pl <- pubidLiteral
      sl <- option "" $ try ( do
                              skipS
                              systemLiteral
                            )
      return $ (k_public, pl) : if null sl then [] else [(k_system, sl)]

htmlContent     :: Parser XmlTrees
htmlContent
    = option []
      ( do
        context <- hContent (id, [])
        pos     <- getPosition
        return $ closeTags pos context
      )
      where
      closeTags _pos (body, [])
          = body []
      closeTags pos' (body, ((tn, al, body1) : restOpen))
          = closeTags pos'
                      ( addHtmlWarn (show pos' ++ ": no closing tag found for \"<" ++ tn ++ " ...>\"")
                        .
                        addHtmlTag tn al body
                        $
                        (body1, restOpen)
                      )

-- ------------------------------------------------------------

hElement        :: Context -> Parser Context
hElement context
    = ( do
        t <- hSimpleData
        return (addHtmlElem t context)
      )
      <|>
      hCloseTag context
      <|>
      hOpenTag context
      <|>
      ( do                      -- wrong tag, take it as text
        pos <- getPosition
        c   <- xmlChar
        return ( addHtmlWarn (show pos ++ " markup char " ++ show c ++ " not allowed in this context")
                 .
                 addHtmlElem (mkText' [c])
                 $
                 context
               )
      )
      <|>
      ( do
        pos <- getPosition
        c <- anyChar
        return ( addHtmlWarn ( show pos
                               ++ " illegal data in input or illegal XML char "
                               ++ show c
                               ++ " found and ignored, possibly wrong encoding scheme used")
                 $
                 context
               )
      )


hSimpleData     :: Parser XmlTree
hSimpleData
    = charData''
      <|>
      hReference'
      <|>
      hComment
      <|>
      pI
      <|>
      cDSect
    where
    charData''
        = do
          t <- many1 (satisfy (\ x -> isXmlChar x && not (x == '<' || x == '&')))
          return (mkText' t)

hCloseTag       :: Context -> Parser Context
hCloseTag context
    = do
      checkString "</"
      n <- lowerCaseName
      skipS0
      pos <- getPosition
      checkSymbol gt ("closing > in tag \"</" ++ n ++ "\" expected") (closeTag pos n context)

hOpenTag        :: Context -> Parser Context
hOpenTag context
    = ( do
        e   <- hOpenTagStart
        hOpenTagRest e context
      )

hOpenTagStart   :: Parser ((SourcePos, String), XmlTrees)
hOpenTagStart
    = do
      np <- try ( do
                  lt
                  pos <- getPosition
                  n <- lowerCaseName
                  return (pos, n)
                )
      skipS0
      as <- hAttrList
      return (np, as)

hOpenTagRest    :: ((SourcePos, String), XmlTrees) -> Context -> Parser Context
hOpenTagRest ((pos, tn), al) context
    = ( do
        checkString "/>"
        return (addHtmlTag tn al id context)
      )
      <|>
      ( do
        context1 <- checkSymbol gt ("closing > in tag \"<" ++ tn ++ "...\" expected") context
        return ( let context2 = closePrevTag pos tn context1
                 in
                 ( if isEmptyHtmlTag tn
                   then addHtmlTag tn al id
                   else openTag tn al
                 ) context2
               )
      )

hAttrList       :: Parser XmlTrees
hAttrList
    = many (try hAttribute)
      where
      hAttribute
          = do
            n <- lowerCaseName
            v <- hAttrValue
            skipS0
            return $ mkAttr' (mkName n) v

hAttrValue      :: Parser XmlTrees
hAttrValue
    = option []
      ( eq >> hAttrValue' )

hAttrValue'     :: Parser XmlTrees
hAttrValue'
    = try ( between dq dq (hAttrValue'' "&\"") )
      <|>
      try ( between sq sq (hAttrValue'' "&\'") )
      <|>
      ( do                      -- HTML allows unquoted attribute values
        cs <- many (noneOf " \r\t\n>\"\'")
        return [mkText' cs]
      )

hAttrValue''    :: String -> Parser XmlTrees
hAttrValue'' notAllowed
    = many ( hReference' <|> singleCharsT notAllowed)

hReference'     :: Parser XmlTree
hReference'
    = try hReferenceT
      <|>
      ( do
        amp
        return (mkText' "&")
      )

hReferenceT     :: Parser XmlTree
hReferenceT
    = do
      r <- referenceT
      return ( if isEntityRef r
               then substRef  r
               else r
             )
    where
    -- optimization: HTML entity refs are substituted by char refs, so a later entity ref substituion isn't required
    substRef r
        = case (lookup en xhtmlEntities) of
          Just i        -> mkCharRef' i
          Nothing       -> r                            -- not found: the entity ref remains as it is
                                                        -- this is also done in the XML parser
{- alternative def
          Nothing       -> mkText' ("&" ++ en ++ ";")   -- not found: the entity ref is taken as text
-}
        where
        en = fromJust . getEntityRef $ r

hContent        :: Context -> Parser Context
hContent context
    = option context
      ( hElement context
        >>=
        hContent
      )

-- hComment allows "--" in comments
-- comment from XML spec does not

hComment                :: Parser XmlTree
hComment
    = do
      c <- between (checkString "<!--") (string "-->") (allBut many "-->")
      return (mkCmt' c)

checkSymbol     :: Parser () -> String -> Context -> Parser Context
checkSymbol p msg context
    = ( p
        >>
        return context
      )
      <|>
      ( do
        pos <- getPosition
        return $ addHtmlWarn (show pos ++ " " ++ msg) context
      )

lowerCaseName   :: Parser String
lowerCaseName
    = do
      n <- name
      return (map toLower n)

upperCaseString :: String -> Parser ()
upperCaseString s
    = try (sequence (map (\ c -> satisfy (( == c) . toUpper)) s)) >> return ()

-- ------------------------------------------------------------

addHtmlTag      :: String -> XmlTrees -> XmlTreeFl -> Context -> Context
addHtmlTag tn al body context
    = e `seq`
      addHtmlElem e context
    where
    e = mkElement' (mkName tn) al (body [])

addHtmlWarn     :: String -> Context -> Context
addHtmlWarn msg
    = addHtmlElem (mkError' c_warn msg)

addHtmlElem    :: XmlTree -> Context -> Context
addHtmlElem elem' (body, openTags)
    = (body . (elem' :), openTags)

openTag         :: String -> XmlTrees -> Context -> Context
openTag tn al (body, openTags)
    = (id, (tn, al, body) : openTags)

closeTag        :: SourcePos -> String -> Context -> Context
closeTag pos n context
    | n `elem` (map ( \ (n1, _, _) -> n1) $ snd context)
        = closeTag' n context
    | otherwise
        = addHtmlWarn (show pos ++ " no opening tag found for </" ++ n ++ ">")
          .
          addHtmlTag n [] id
          $
          context
    where
    closeTag' n' (body', (n1, al1, body1) : restOpen)
        = close context1
          where
          context1
              = addHtmlTag n1 al1 body' (body1, restOpen)
          close
              | n' == n1
                = id
              | n1 `isInnerHtmlTagOf` n'
                  = closeTag pos n'
              | otherwise
                = addHtmlWarn (show pos ++ " no closing tag found for \"<" ++ n1 ++ " ...>\"")
                  .
                  closeTag' n'
    closeTag' _ _
        = error "illegal argument for closeTag'"

closePrevTag    :: SourcePos -> String -> Context -> Context
closePrevTag _pos _n context@(_body, [])
    = context
closePrevTag pos n context@(body, (n1, al1, body1) : restOpen)
    | n `closes` n1
        = closePrevTag pos n
          ( addHtmlWarn (show pos ++ " tag \"<" ++ n1 ++ " ...>\" implicitly closed by opening tag \"<" ++ n ++ " ...>\"")
            .
            addHtmlTag n1 al1 body
            $
            (body1, restOpen)
          )
    | otherwise
        = context

-- ------------------------------------------------------------
--
-- taken from HaXml and extended

isEmptyHtmlTag  :: String -> Bool
isEmptyHtmlTag n
    = n `elem`
      emptyHtmlTags

emptyHtmlTags   :: [String]
emptyHtmlTags
    = [ "area"
      , "base"
      , "br"
      , "col"
      , "frame"
      , "hr"
      , "img"
      , "input"
      , "link"
      , "meta"
      , "param"
      ]

isInnerHtmlTagOf        :: String -> String -> Bool
n `isInnerHtmlTagOf` tn
    = n `elem`
      ( fromMaybe [] . lookup tn
      $ [ ("body",    ["p"])
        , ("caption", ["p"])
        , ("dd",      ["p"])
        , ("div",     ["p"])
        , ("dl",      ["dt","dd"])
        , ("dt",      ["p"])
        , ("li",      ["p"])
        , ("map",     ["p"])
        , ("object",  ["p"])
        , ("ol",      ["li"])
        , ("table",   ["th","tr","td","thead","tfoot","tbody"])
        , ("tbody",   ["th","tr","td"])
        , ("td",      ["p"])
        , ("tfoot",   ["th","tr","td"])
        , ("th",      ["p"])
        , ("thead",   ["th","tr","td"])
        , ("tr",      ["th","td"])
        , ("ul",      ["li"])
        ]
      )

closesHtmlTag
  , closes :: String -> String -> Bool

closesHtmlTag   = closes

"a"     `closes` "a"                                    = True
"li"    `closes` "li"                                   = True
"th"    `closes`  t    | t `elem` ["th","td"]           = True
"td"    `closes`  t    | t `elem` ["th","td"]           = True
"tr"    `closes`  t    | t `elem` ["th","td","tr"]      = True
"dt"    `closes`  t    | t `elem` ["dt","dd"]           = True
"dd"    `closes`  t    | t `elem` ["dt","dd"]           = True
"hr"    `closes`  "p"                                   = True
"colgroup"
        `closes` "colgroup"                             = True
"form"  `closes` "form"                                 = True
"label" `closes` "label"                                = True
"map"   `closes` "map"                                  = True
"object"
        `closes` "object"                               = True
_       `closes` t  | t `elem` ["option"
                               ,"script"
                               ,"style"
                               ,"textarea"
                               ,"title"
                               ]                        = True
t       `closes` "select" | t /= "option"               = True
"thead" `closes` t  | t `elem` ["colgroup"]             = True
"tfoot" `closes` t  | t `elem` ["thead"
                               ,"colgroup"]             = True
"tbody" `closes` t  | t `elem` ["tbody"
                               ,"tfoot"
                               ,"thead"
                               ,"colgroup"]             = True
t       `closes` t2 | t `elem` ["h1","h2","h3"
                               ,"h4","h5","h6"
                               ,"dl","ol","ul"
                               ,"table"
                               ,"div","p"
                               ]
                      &&
                      t2 `elem` ["h1","h2","h3"
                                ,"h4","h5","h6"
                                ,"p"                    -- not "div"
                                ]                       = True
_       `closes` _                                      = False

-- ------------------------------------------------------------
