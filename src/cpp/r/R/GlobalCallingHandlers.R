#
# GlobalCallingHandlers.R
#
# Copyright (C) 2025 by Posit Software, PBC
#
# Unless you have received this program directly from Posit Software pursuant
# to the terms of a commercial license agreement with Posit Software, then
# this program is licensed to you under the terms of version 3 of the
# GNU Affero General Public License. This program is distributed WITHOUT
# ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
# MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
# AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
#
#


# Make sure these are in sync with AnsiEscapes.hpp.
.rs.setVar("ansiEscapeGroup", list(
   error   = "\033G1;",
   warning = "\033G2;",
   message = "\033G3;",
   end     = "\033g"
))

.rs.setVar("ansiEscapeHighlight", list(
   error   = "\033H1;",
   warning = "\033H2;",
   message = "\033H3;",
   end     = "\033h"
))


.rs.addFunction("globalCallingHandlers.initialize", function()
{
   # Remove any previously-registered handlers.
   globalCallingHandlers(NULL)
   
   # Install our handlers.
   if (.rs.uiPrefs$consoleHighlightConditions$get() == "errors_warnings_messages")
   {
      globalCallingHandlers(
         error   = .rs.globalCallingHandlers.onError,
         warning = .rs.globalCallingHandlers.onWarning,
         message = .rs.globalCallingHandlers.onMessage
      )
   }
   else if (.rs.uiPrefs$consoleHighlightConditions$get() == "errors_warnings")
   {
      globalCallingHandlers(
         error   = .rs.globalCallingHandlers.onError,
         warning = .rs.globalCallingHandlers.onWarning
      )
   }
   else if (.rs.uiPrefs$consoleHighlightConditions$get() == "errors")
   {
      globalCallingHandlers(
         error   = .rs.globalCallingHandlers.onError
      )
   }
})

.rs.addFunction("globalCallingHandlers.initializeCall", function()
{
   body(.rs.globalCallingHandlers.initialize)
})

.rs.addFunction("globalCallingHandlers.onError", function(cnd)
{
   .rs.globalCallingHandlers.onErrorImpl(cnd)
})

.rs.addFunction("globalCallingHandlers.onErrorImpl", function(cnd)
{
   .Call("rs_errorOutputPending", PACKAGE = "(embedding)")
})

.rs.addFunction("globalCallingHandlers.onWarning", function(cnd)
{
   .rs.globalCallingHandlers.onWarningImpl(cnd)
})

.rs.addFunction("globalCallingHandlers.onWarningImpl", function(cnd)
{
   if (.rs.globalCallingHandlers.shouldHandleWarning(cnd))
   {
      msg <- .rs.globalCallingHandlers.formatCondition(cnd, "Warning", "warning")
      writeLines(msg, con = stderr())
      invokeRestart("muffleWarning")
   }
})

.rs.addFunction("globalCallingHandlers.onMessage", function(cnd)
{
   .rs.globalCallingHandlers.onMessageImpl(cnd)
})

.rs.addFunction("globalCallingHandlers.onMessageImpl", function(cnd)
{
   if (.rs.globalCallingHandlers.shouldHandleMessage(cnd))
   {
      msg <- .rs.globalCallingHandlers.formatCondition(cnd, NULL, "message")
      cat(msg, file = stderr())
      invokeRestart("muffleMessage")
   }
})

.rs.addFunction("globalCallingHandlers.shouldHandleWarning", function(cnd)
{
   pref <- .rs.uiPrefs$consoleHighlightConditions$get()
   if (!grepl("warnings", pref, fixed = TRUE))
      return(FALSE)
   
   # If the user is opting into bundling warnings, just let the default
   # R warning handler take over. We also need to ignore if warnings are
   # disabled entirely (via a negative value for the option).
   warn <- getOption("warn", default = 0L)
   if (warn <= 0L)
      return(FALSE)
   
   # I can't imagine anyone is actually using this in the wild, but...
   expr <- getOption("warning.expression", default = NULL)
   if (!is.null(expr))
      return(FALSE)
   
   # rlang doesn't apply any custom styles to emitted warnings,
   # so handle warnings even if they have custom classes
   TRUE
})

.rs.addFunction("globalCallingHandlers.shouldHandleMessage", function(cnd)
{
   pref <- .rs.uiPrefs$consoleHighlightConditions$get()
   if (!grepl("messages", pref, fixed = TRUE))
      return(FALSE)
   
   !inherits(cnd, "rlang_message")
})

.rs.addFunction("globalCallingHandlers.formatCondition", function(cnd, label, type)
{
   msg <- conditionMessage(cnd)
   text <- if (is.null(label))
   {
      msg
   }
   else if (is.null(conditionCall(cnd)))
   {
      # Hacky way to respect R's available translations while only colouring
      # the first word in the prefix
      prefix <- gettext(sprintf("%s: ", label), domain = "R")
      colonIndex <- regexpr(":", prefix, fixed = TRUE)
      lhs <- substr(prefix, 1L, colonIndex - 1L)
      rhs <- substr(prefix, colonIndex, .Machine$integer.max)
      prefix <- paste0(.rs.globalCallingHandlers.highlight(lhs, type), rhs)
      sprintf("%s%s", prefix, msg)
   }
   else
   {
      # Hacky way to respect R's available translations while only colouring
      # the first word in the prefix
      prefix <- gettext(sprintf("%s in ", label), domain = "R")
      parts <- strsplit(prefix, " ", fixed = TRUE)[[1L]]
      parts[[1L]] <- .rs.globalCallingHandlers.highlight(parts[[1L]], type)
      prefix <- paste(parts, collapse = " ")
      
      # R seems to just use the first line of the deparsed call?
      cll <- .rs.deparseCall(conditionCall(cnd))[[1L]]
      header <- sprintf("%s %s :", prefix, cll)
      if (nchar(header) + nchar(msg) >= 77L)
         sprintf("%s\n  %s", header, msg)
      else
         sprintf("%s %s", header, msg)
   }
   
   .rs.globalCallingHandlers.group(text, type)
})

.rs.addFunction("globalCallingHandlers.group", function(text, type)
{
   paste0(.rs.ansiEscapeGroup[[type]], text, .rs.ansiEscapeGroup[["end"]])
})

.rs.addFunction("globalCallingHandlers.highlight", function(text, type = "error")
{
   paste0(.rs.ansiEscapeHighlight[[type]], text, .rs.ansiEscapeHighlight[["end"]])
})
