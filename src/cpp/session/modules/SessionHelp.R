#
# SessionHelp.R
#
# Copyright (C) 2022 by Posit Software, PBC
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

# use html help
options(help_type = "html")

# cached encoding of help files for installed packages
.rs.setVar("packageHelpEncodingEnv", new.env(parent = emptyenv()))

.rs.addFunction("httpdPortIsFunction", function()
{
   is.function(tools:::httpdPort)
})

.rs.addFunction("httpdPort", function()
{
   if (.rs.httpdPortIsFunction())
      as.character(tools:::httpdPort())
   else
      as.character(tools:::httpdPort)
})

.rs.addFunction("initHelp", function(port, isDesktop)
{ 
   # function to set the help port
   setHelpPort <- function() {
      if (.rs.httpdPortIsFunction()) {
         tools:::httpdPort(port)
      } else {
         env <- environment(tools::startDynamicHelp)
         unlockBinding("httpdPort", env)
         assign("httpdPort", port, envir = env)
         lockBinding("httpdPort", env)   
      }
   }
   
   # for desktop mode see if R can successfully initialize the httpd
   # server -- if it can't then perhaps localhost ports are blocked,
   # in this case we take over help entirely
   if (isDesktop) 
   {
      # start the help server if it hasn't previously been started
      # (suppress warnings and messages because if there is a problem
      # binding to a local port we are going to patch this up by 
      # redirecting all traffic to our local peer)
      if (.rs.httpdPort() <= 0L)
         suppressWarnings(suppressMessages(tools::startDynamicHelp()))
      
      # if couldn't start it then set the help port directly so that
      # help requests still flow through our local peer connection
      if (.rs.httpdPort() <= 0L)
      {
         setHelpPort()
         return (TRUE)
      }
      else
      {
         return (FALSE)
      }
   }
   # always take over help in server mode
   else 
   { 
      # stop the help server if it was previously started e.g. by .Rprofile
      if (.rs.httpdPort() > 0L)
         suppressMessages(tools::startDynamicHelp(start=FALSE))
      
      # set the help port
      setHelpPort()
      
      # indicate we should handle custom internally
      return (TRUE)
   }
})

.rs.addFunction( "handlerLookupError", function(path, query=NULL, ...)
{
   payload = paste(
      "<h3>R Custom HTTP Handler Not Found</h3>",
      "<p>Unable to locate custom HTTP handler for",
      "<i>", .rs.htmlEscape(path), "</i>",
      "<p>Is the package which implements this HTTP handler loaded?</p>")
   
   list(payload, "text/html", character(), 404)
});

.rs.setVar("topicsEnv", new.env(parent = emptyenv()))

.rs.addJsonRpcHandler("suggest_topics", function(query)
{
   pkgpaths <- path.package(quiet = TRUE)
   
   # read topics from
   topics <- lapply(pkgpaths, function(pkgpath) tryCatch({
      
      if (exists(pkgpath, envir = .rs.topicsEnv))
         return(get(pkgpath, envir = .rs.topicsEnv))
      
      aliases <- file.path(pkgpath, "help/aliases.rds")
      index <- file.path(pkgpath, "help/AnIndex")
      
      value <- if (file.exists(aliases)) {
         names(readRDS(aliases))
      } else if (file.exists(index)) {
         data <- read.table(index, sep = "\t")
         data[, 1]
      }
      
      assign(pkgpath, value, envir = .rs.topicsEnv)
      
   }, error = function(e) NULL))
   
   flat <- unlist(topics, use.names = FALSE)
   
   # order matches by subsequence match score
   scores <- .rs.scoreMatches(tolower(flat), tolower(query))
   ordered <- flat[order(scores, nchar(flat))]
   matches <- unique(ordered[.rs.isSubsequence(tolower(ordered), tolower(query))])
   
   # force first character to match, but allow typos after.
   # also keep matches with one or more leading '.', so that e.g.
   # the prefix 'libpaths' can match '.libPaths'
   if (nzchar(query)) {
      first <- .rs.escapeForRegex(substring(query, 1L, 1L))
      pattern <- sprintf("^[.]*[%s]", first)
      matches <- grep(pattern, matches, value = TRUE, perl = TRUE)
   }
   
   matches
   
})

.rs.addFunction("getHelpFromObject", function(object, envir, name = NULL)
{
   # Try to find the associated namespace of the object
   namespace <- NULL
   if (is.primitive(object))
      namespace <- "base"
   else if (is.function(object))
   {
      envString <- .rs.format(environment(object))[[1L]]
      
      # Strip out the irrelevant bits of the package name. We'd like
      # to just use 'regexpr' but its output is funky with older versions
      # of R.
      if (!grepl("namespace:", envString))
         return()
      
      namespace <- sub(".*namespace:", "", envString)
      namespace <- sub(">.*", "", namespace)
   }
   else if (isS4(object))
      namespace <- attr(class(object), "package")
   
   if (is.null(namespace))
      return()
   
   # Get objects from that namespace
   ns <- try(asNamespace(namespace), silent = TRUE)
   if (inherits(ns, "try-error"))
      return()
   
   # Datasets don't live in the namespace -- ennumerate them separately
   # We have to avoid the 'base' package, though.
   datasets <- tryCatch(
      suppressWarnings(data(package = namespace)),
      error = function(e) NULL
   )
   
   objectNames <- objects(ns, all.names = TRUE)
   datasetNames <- unname(grep(" ", datasets$results[, "Item"], fixed = TRUE, value = TRUE, invert = TRUE))
   
   objects <- tryCatch(
      mget(objectNames, envir = ns, inherits = TRUE),
      error = function(e) NULL
   )
   
   # Try to get the datasets from the namespace. These will only exist if they have
   # been explicitly loaded, so be careful to tryCatch here.
   data <- lapply(datasetNames, function(x) {
      tryCatch(
         get(x, envir = ns),
         error = function(e) NULL
      )
   })
   
   # Combine them together
   if (length(data))
   {
      objects <- c(objects, data)
      objectNames <- c(objectNames, datasetNames)
   }
   
   # Find which object is actually identical to the one we have
   success <- FALSE
   for (i in seq_along(objects))
   {
      if (!identical(class(object), class(objects[[i]])))
         next
      
      # Once again, 'ignore.environment' is not available in older R's
      # identical, so construct and eval a call to 'base::identical'.
      formals <- as.list(formals(base::identical))
      formals$x <- object
      formals$y <- objects[[i]]
      if ("ignore.environment" %in% names(formals))
         formals[["ignore.environment"]] <- TRUE
      
      result <- tryCatch(
         do.call(base::identical, formals),
         error = function(e) FALSE
      )
      
      if (result)
      {
         success <- TRUE
         break
      }
   }
   
   if (success)
   {
      # Use that name for the help lookup
      object <- objects[[i]]
      objectName <- objectNames[[i]]
      
      # use the function name seen in the
      # source document if provided
      sigName <- if (is.null(name))
         objectName
      else
         name
      
      # Get the associated signature for functions
      signature <- NULL
      if (is.function(object))
         signature <- sub("function ", sigName, .rs.getSignature(object))
      
      result <- .rs.getHelp(topic = objectName, package = namespace, sig = signature)
      if (length(result))
         return(result)
      
      # If the previous lookup failed, perhaps it was an S3 method for which no
      # documentation was available. Fall back to generic documentation.
      dotPos <- gregexpr(".", objectName, fixed = TRUE)[[1]]
      for (i in seq_along(dotPos))
      {
         maybeGeneric <- substring(objectName, 1, dotPos[[i]] - 1)
         methods <- suppressWarnings(
            tryCatch(
               eval(substitute(methods(x), list(x = maybeGeneric)), envir = envir),
               error = function(e) NULL
            )
         )
         
         if (objectName %in% methods)
         {
            result <- .rs.getHelp(maybeGeneric)
            if (length(result))
               return(result)
         }
      }
   }
   
   # Fail -- return NULL
   NULL
})

.rs.addFunction("getHelpRpcImpl", function(what, from, type, envir)
{
   # If we've encoded the package and function in 'what', pull it out
   if (grepl("::.", what))
   {
      splat <- strsplit(what, "::", fixed = TRUE)[[1]]
      from <- splat[[1]]
      what <- splat[[2]]
   }
   
   # Avoid install.packages hook
   if (what == "install.packages" &&
       type == .rs.acCompletionTypes$ARGUMENT &&
       is.null(from))
   {
      return(.rs.getHelp("install.packages", "utils"))
   }
   
   # Help for options
   if (type == .rs.acCompletionTypes$OPTION)
      return(.rs.getHelp("options", "base", subset = FALSE))
   
   if (type %in% c(.rs.acCompletionTypes$S4_GENERIC,
                   .rs.acCompletionTypes$S4_METHOD))
   {
      # Try getting methods for the method from the associated package
      if (!is.null(help <- .rs.getHelp(paste(what, "methods", sep = "-"), from)))
         return(help)
      
      # Try getting help from anywhere
      if (!is.null(help <- .rs.getHelp(what, from)))
         return(help)
      
      # Give up
      return()
   }
   
   if (type %in% c(.rs.acCompletionTypes$FUNCTION,
                   .rs.acCompletionTypes$S4_GENERIC,
                   .rs.acCompletionTypes$S4_METHOD,
                   .rs.acCompletionTypes$R5_METHOD))
      return(.rs.getHelpFunction(what, from))
   else if (type %in% c(.rs.acCompletionTypes$ARGUMENT, .rs.acCompletionTypes$SECUNDARY_ARGUMENT))
      return(.rs.getHelpArgument(what, from, parent.frame()))
   else if (type == .rs.acCompletionTypes$PACKAGE)
      return(.rs.getHelpPackage(what))
   else if (type == .rs.acCompletionTypes$DATATABLE_SPECIAL_SYMBOL)
      return(.rs.getHelpDataTableSpecialSymbol(what))
   else if (type == .rs.acCompletionTypes$COLUMN)
      return(.rs.getHelpColumn(what, from, envir))
   else if (type == .rs.acCompletionTypes$DATAFRAME)
      return(.rs.getHelpDataFrame(what, from, envir))
   else if (length(from) && length(what))
      return(.rs.getHelp(what, from))
   else
      return()
})

.rs.addJsonRpcHandler("get_help", function(what, from, type)
{
   # Protect against missing type
   if (!length(type))
      return()
   
   envir <- .rs.getActiveFrame()
   out <- .rs.getHelpRpcImpl(what, from, type, envir)
   if (is.null(out))
      return()
   
   out$type <- type
   out
})

.rs.addJsonRpcHandler("get_custom_help", function(helpHandler,
                                                  topic,
                                                  source,
                                                  language)
{
   # use own handler for Python language help
   if (identical(language, "Python"))
      return(.rs.python.getHelp(topic, source))
   
   helpHandlerFunc <- tryCatch(eval(parse(text = helpHandler)), 
                               error = function(e) NULL)
   if (!is.function(helpHandlerFunc))
      return()
   
   results <- helpHandlerFunc("completion", topic, source)
   if (!is.null(results)) {
      results$description <- .rs.markdownToHTML(results$description)
   }
     
   results 
})

.rs.addJsonRpcHandler("get_custom_parameter_help", function(helpHandler,
                                                            source,
                                                            language)
{
   # use own handler for Python language help
   if (identical(language, "Python"))
      return(.rs.python.getParameterHelp(source))
   
   helpHandlerFunc <- tryCatch(eval(parse(text = helpHandler)), 
                               error = function(e) NULL)
   if (!is.function(helpHandlerFunc))
      return()
   
   results <- helpHandlerFunc("parameter", NULL, source)
   if (!is.null(results)) {
      results$type <- .rs.acCompletionTypes$ARGUMENT
      results$arg_descriptions <- sapply(results$arg_descriptions, .rs.markdownToHTML)
   }
   
   results
})

.rs.addJsonRpcHandler("show_custom_help_topic", function(helpHandler, topic, source) {
   
   helpHandlerFunc <- tryCatch(
      eval(parse(text = helpHandler)), 
      error = function(e) NULL
   )
   
   if (!is.function(helpHandlerFunc))
      return()
   
   # workaround for broken help in reticulate 1.18
   if (identical(helpHandler, "reticulate:::help_handler"))
   {
      text <- paste(source, topic, sep = ".")
      .Call("rs_showPythonHelp", text, PACKAGE = "(embedding)")
      return()
   }
   
   url <- helpHandlerFunc("url", topic, source)
   if (!is.null(url) && nzchar(url)) # handlers return "" for no help topic
      utils::browseURL(url)
})

.rs.addJsonRpcHandler("get_vignette_title", function(topic, package)
{
   title <- tryCatch(utils::vignette(topic, package)$Title, 
                     error = function(e) "", 
                     warning = function(e) "")
   .rs.scalar(title)         
})

.rs.addJsonRpcHandler("get_vignette_description", function(topic, package)
{
   description <- tryCatch(
      {
         v <- vignette(topic, package)

         Dir <- v$Dir
         File <- v$File
         if (grepl("[.]Rmd$", File))
         {
            description <- rmarkdown::yaml_front_matter(file.path(Dir, "doc", File))$description
            if (is.null(description))
            {
               description <- ""
            }
            description
         }
         else ""

      }, 
      error = function(e) "", 
      warning = function(e) "")
   .rs.scalar(description)         
})

.rs.addJsonRpcHandler("show_vignette", function(topic, package)
{
   # First, check for an explicitly registered vignette
   vignette <- tryCatch(utils::vignette(topic, package), condition = identity)
   if (!inherits(vignette, "condition"))
      return(print(vignette))
   
   # Try falling back to opening bundled documentation that's not
   # explicitly registered as a vignette.
   exts <- c("pdf", "html")
   for (ext in exts) {
      suffix <- sprintf("doc/%s.%s", topic, ext)
      path <- system.file(suffix, package = package, mustWork = FALSE)
      if (nzchar(path))
         return(browseURL(path))
   }
 
   # If we couldn't find the vignette, re-throw the original error.
   stop(conditionMessage(vignette), call. = FALSE)
})

.rs.addFunction("getHelpColumn", function(name, src, envir = parent.frame())
{
   tryCatch(
      .rs.getHelpColumnImpl(name, src, envir),
      error = function(e) NULL
   )
})

.rs.addFunction("getHelpColumnImpl", function(name, src, envir = parent.frame())
{
   data <- .rs.getAnywhere(src, envir)
   if (is.null(data))
      return(NULL)
   
   described <- .rs.describeObject(data, name)
   description <- described$description
   type <- described$type
   size <- described$length
   
   list(
      html = paste0("<h2></h2><h3>Description</h3><p>", description, "</p>"),
      signature = paste0("<", type, "> [", size, "]"),
      pkgname = src,
      help = FALSE
   )
   
})

.rs.addFunction("getHelpDataFrame", function(name, src, envir = parent.frame())
{
   # try and retrieve the help documentation
   out <- .rs.getHelp(name, src)
   
   # Return help page as-is if requested by user
   showDataPreview <- getOption("rstudio.help.showDataPreview", default = TRUE)
   if (!showDataPreview)
      return(out)
   
   showDataPreview <- .rs.readUserPref("show_data_preview")
   if (!identical(showDataPreview, TRUE))
      return(out)

   # try and figure out the data + title
   data <- NULL
   title <- name
   
   # If 'src' is the name of something on the search path, grab the data
   pos <- match(src, search(), nomatch = -1L)
   if (pos >= 0)
   {
      data <- tryCatch(get(name, pos = pos), error = function(e) NULL)
   }

   dataFoundAnywhere <- FALSE
   # if that failed, try to look it up anywhere
   if (is.null(data))
   {
      title <- paste0(src, "$", name)
      data <- .rs.getAnywhere(title, envir)

      # if we still couldn't find any data, just use the help document
      if (is.null(data))
      {
         return(out)
      }
   
      dataFoundAnywhere <- TRUE
   }

   # Generate the help pre-amble
   if (is.null(out))
   {
      fmt <- paste(
         "<h2>%s</h2>",
         "<h3>Description</h3>",
         "<p>%i obs. of %i %s</p>",
         sep = ""
      )
      
      vbls <- if (ncol(data) == 1) "variable" else "variables"
      html <- sprintf(fmt, name, nrow(data), ncol(data), vbls)
      
      out <- list(
         html = html,
         signature = "-", 
         pkgname = src, 
         help = FALSE   
      )
   }
   
   # NOTE: We previously tried assigning and using cached data, but this is
   # not safe since help documents are cached after they are first created.
   #
   # Instead, we need to make sure the data viewer references the actual
   # object in the place it's defined.
   
   # Limit the number of columns to the first `maxDisplayColumns`
   # number of columns. E.g. if data_viewer_max_columns=50, then
   # we'll only load and show the first 50 columns of the data frame
   # in the help preview.
   maxDisplayColumns <- .rs.readUiPref("data_viewer_max_columns")

   # build a uri
   attrs <- c(
      obj       = title,
      max_rows  = 1000,
      max_cols  = maxDisplayColumns
   )
   
   # only include env if we didn't find the data from "anywhere"
   if (!dataFoundAnywhere)
   {
      attrs <- c(attrs, env = src)
   }
   
   uri <- paste(
      "grid_resource/gridviewer.html",
      paste(names(attrs), attrs, sep = "=", collapse = "&"),
      sep = "?"
   )
   
   out$view <- uri
   out
})

.rs.addFunction("getHelpFunction", function(name, src, envir = parent.frame())
{
   # If 'src' is the name of something on the search path, get that object
   # from the search path, then attempt to get help based on that object
   pos <- match(src, search(), nomatch = -1L)
   if (pos >= 0)
   {
      object <- tryCatch(get(name, pos = pos), error = function(e) NULL)
      if (!is.null(object))
         return(.rs.getHelpFromObject(object, envir, name))
   }
   
   # Otherwise, check to see if there is an object 'src' in the global env
   # from which we can pull the object
   container <- tryCatch(eval(parse(text = src), envir = .GlobalEnv), error = function(e) NULL)
   if (!is.null(container))
   {
      object <- tryCatch(eval(call("$", container, name)), error = function(e) NULL)
      if (!is.null(object))
         return(.rs.getHelpFromObject(object, envir, name))
   }
   
   # Otherwise, try to get help in the vanilla way
   .rs.getHelp(name, src, getSignature = TRUE)
})

.rs.addFunction("getHelpPackage", function(pkgName)
{
   # We might be getting the completion with colons appended, so strip those out.
   pkgName <- sub(":*$", "", pkgName, perl = TRUE)
   topic <- paste(pkgName, "-package", sep = "")
   out <- .rs.getHelp(topic, pkgName)
   if (is.null(out))
   {
      pkgDescription <- suppressWarnings(utils::packageDescription(pkgName))
      if (!identical(pkgDescription, NA)) 
      {
         title <- .rs.htmlEscape(pkgDescription$Title)
         description <- .rs.htmlEscape(pkgDescription$Description)
         
         # Format like what HelpInfo.parse() expects
         out <- list(
            html = paste0("<h2>", title, "</h2><h3>Description</h3><p>", description, "</p>"),
            signature = NULL, 
            pkgname = pkgName
         )
      }
   }
   out
})

.rs.addFunction("getHelpDataTableSpecialSymbol", function(what)
{
   html <- strsplit(.rs.getHelp(what, "data.table", subset = FALSE)$html, "\n")[[1L]]
   description <- grep(paste0("<p><code>", what, "</code>[^,]"), html, value = TRUE)
   description <- sub("<li><p>", "", description)

   out <- list(
      html = paste0("<h2>data.table special symbol ", what, "</h2><h3>Description</h3><p>", description, "</p>"),
      signature = NULL, 
      pkgname = "data.table"
   )
   out
})

.rs.addFunction("getHelpArgument", function(functionName, src, envir)
{
   if (is.null(src))
   {
      object <- .rs.getAnywhere(functionName, envir)
         if (!is.null(object))
         return(.rs.getHelpFromObject(object, envir, functionName))
   }
   else
   {
      pos <- match(src, search(), nomatch = -1L)
      
      if (pos >= 0)
      {
         object <- tryCatch(get(functionName, pos = pos), error = function(e) NULL)
         if (!is.null(object))
            return(.rs.getHelpFromObject(object, envir, functionName))
      }
   }
   
   .rs.getHelp(functionName, src)
})

.rs.addFunction("makeHelpCall", function(topic,
                                         package = NULL,
                                         help_type = "html")
{
   # build help call
   call <- substitute(
      utils::help(TOPIC, package = PACKAGE, help_type = "html"),
      list(TOPIC = topic, PACKAGE = package)
   )
   
   # support devtools shims
   if ("devtools_shims" %in% search())
      call[[1L]] <- quote(help)
   
   # return generated call
   call
})

.rs.addFunction("packageHelpEncoding", function(packagePath)
{
   if (!is.character(packagePath) || !file.exists(packagePath))
      return(.rs.packageHelpEncodingDefault())
   
   if (exists(packagePath, envir = .rs.packageHelpEncodingEnv))
      return(get(packagePath, envir = .rs.packageHelpEncodingEnv))
   
   encoding <- tryCatch(
      .rs.packageHelpEncodingImpl(packagePath),
      error = function(e) .rs.packageHelpEncodingDefault()
   )
   
   assign(packagePath, encoding, envir = .rs.packageHelpEncodingEnv)
   encoding
   
})

.rs.addFunction("packageHelpEncodingImpl", function(packagePath)
{
   desc <- .rs.readPackageDescription(packagePath)
   .rs.nullCoalesce(desc$Encoding, .rs.packageHelpEncodingDefault())
})

.rs.addFunction("packageHelpEncodingDefault", function()
{
   pref <- .rs.readUiPref("default_encoding")
   .rs.nullCoalesce(pref, "UTF-8")
})

.rs.addFunction("getHelp", function(topic,
                                    package = "",
                                    sig = NULL,
                                    subset = TRUE,
                                    getSignature = FALSE)
{
   # ensure topic and package are not zero-length
   if (!length(package))
      package <- ""
   
   if (!length(topic))
      topic <- ""
   
   # completions from the search path might have the 'package:' prefix;
   # let's strip that out
   package <- sub("package:", "", package, fixed = TRUE)
   
   # if the package is not provided, but we're getting help on e.g.
   # 'stats::rnorm', then split up the topic into the appropriate pieces
   if (package == "" && any(grepl(":{2,3}", topic, perl = TRUE)))
   {
      splat <- strsplit(topic, ":{2,3}", perl = TRUE)[[1]]
      topic <- splat[[2]]
      package <- splat[[1]]
   }
   
   # don't provide help for objects in the global environment
   if (identical(package, ".GlobalEnv"))
      return()
   
   helpfiles <- .rs.tryCatch({
      call <- .rs.makeHelpCall(topic, if (nzchar(package)) package)
      eval(call, envir = globalenv())
   })
   
   # if we failed to retrieve any help files, check if this might
   # happen to be an S3 method where the generic is documented
   #
   # https://github.com/rstudio/rstudio/issues/14232
   if (length(helpfiles) <= 0)
   {
      topic <- gsub("\\..*", "", topic)
      call <- .rs.makeHelpCall(topic, if (nzchar(package)) package)
      helpfiles <- eval(call, envir = globalenv())
   }
   
   if (length(helpfiles) <= 0)
      return()
   
   # handle devtools help topics specially
   isDevTopic <- inherits(helpfiles, "dev_topic") && "pkgload" %in% loadedNamespaces()
   if (isDevTopic)
   {
      # devtools help
      status <- .rs.tryCatch({
         package <- helpfiles$pkg
         docPath <- file.path(tempdir(), sprintf(".R/doc/html/%s.html", helpfiles$topic))
         dir.create(dirname(docPath), recursive = TRUE, showWarnings = FALSE)
         pkgload:::topic_write_html(helpfiles, path = docPath)
      })
      
      if (inherits(status, "error"))
         return()
      
      html <- paste(readLines(docPath, warn = FALSE), collapse = "\n")
   }
   else
   {
      # regular old help
      file <- helpfiles[[1]]
      path <- dirname(file)
      dirpath <- dirname(path)
      package <- basename(dirpath)
      
      query <- sprintf("/library/%s/html/%s.html", package, basename(file))
      html <- suppressWarnings(tools:::httpd(query, NULL, NULL))$payload
   }
   
   # try to figure out the encoding for the provided HTML
   if (nzchar(package))
   {
      packagePath <- system.file(package = package)
      if (nzchar(packagePath))
      {
         encoding <- .rs.packageHelpEncoding(packagePath)
         if (identical(encoding, "UTF-8"))
            Encoding(html) <- "UTF-8"
      }
   }
   
   # older releases of R may return HTML (notably, error pages) as
   # a character vector with one line for each bit of output
   #
   # https://github.com/wch/r-source/commit/e22517c9036a2a06d8778b2a782d393224e355af
   html <- paste(html, collapse = "\n")
   
   # try to extract HTML body
   match <- suppressWarnings(regexpr('<body>.*</body>', html))
   if (match < 0)
   {
      html <- NULL
   }
   else
   {
      html <- substring(html, match + 6, match + attr(match, 'match.length') - 1 - 7)
      
      if (subset)
      {   
         slotsMatch <- suppressWarnings(regexpr('<h3>Slots</h3>', html))
         detailsMatch <- suppressWarnings(regexpr('<h3>Details</h3>', html))
         
         match <- if (slotsMatch > detailsMatch) slotsMatch else detailsMatch
         if (match >= 0)
            html <- substring(html, 1, match - 1)
      }
   }
   
   # Try to resolve function signatures for help
   if (is.null(sig) && getSignature)
   {
      object <- NULL
      if (package %in% loadedNamespaces())
      {
         object <- tryCatch(
            get(topic, envir = asNamespace(package)),
            error = function(e) NULL
         )
      }
      
      if (!length(object))
      {
         object <- tryCatch(
            get(topic, pos = globalenv()),
            error = function(e) NULL
         )
      }
      
      if (is.function(object))
      {
         sig <- .rs.getSignature(object)
         sig <- gsub('^function ', topic, sig)
      }
   }
   
   list(
      html = html,
      signature = sig,
      pkgname = package
   )
})

.rs.addJsonRpcHandler("show_help_topic", function(what, from, type)
{
   # strip off a 'package:' prefix if necessary
   if (is.character(from) && nzchar(from))
      from <- sub("^package:", "", from)

   # handle dev topics and objects imported in NAMESPACE if F1 is pressed
   if ("devtools_shims" %in% search() && requireNamespace("pkgload", quietly = TRUE))
   {
     # Find packages loaded via load_all()
     packages <- .rs.tryCatch(pkgload:::dev_packages())
     if (is.character(packages) && from %in% packages)
     {
       from <- NULL
       dev_help <- tryCatch(pkgload::dev_help(what), error = function(e) NULL)
       if (length(dev_help) > 0)
         return(print(dev_help))
     }
   }

   if (type == .rs.acCompletionTypes$FUNCTION)
      .rs.showHelpTopicFunction(what, from)
   else if (type == .rs.acCompletionTypes$ARGUMENT)
      .rs.showHelpTopicArgument(from)
   else if (type == .rs.acCompletionTypes$PACKAGE)
      .rs.showHelpTopicPackage(what)
   else
      .rs.showHelpTopic(what, from)
})

.rs.addFunction("showHelpTopicFunction", function(topic, package)
{
   if (is.null(package) && grepl(":{2,3}", topic, perl = TRUE))
   {
      splat <- strsplit(topic, ":{2,3}", perl = TRUE)[[1]]
      topic <- splat[[2]]
      package <- splat[[1]]
   }
   
   if (!is.null(package))
      requireNamespace(package, quietly = TRUE)
   
   call <- .rs.makeHelpCall(topic, package)
   print(eval(call, envir = parent.frame()))
})

.rs.addFunction("showHelpTopicArgument", function(functionName)
{
   topic <- functionName
   pkgName <- NULL
   
   if (grepl(":{2,3}", functionName, perl = TRUE))
   {
      splat <- strsplit(functionName, ":{2,3}", perl = TRUE)[[1]]
      topic <- splat[[2]]
      pkgName <- splat[[1]]
   }
   
   call <- .rs.makeHelpCall(topic, pkgName)
   print(eval(call, envir = parent.frame()))
})

.rs.addFunction("showHelpTopicPackage", function(pkgName)
{
   pkgName <- sub(":*$", "", pkgName)
   topic <- paste(pkgName, "-package", sep = "")
   call <- .rs.makeHelpCall(topic, pkgName)
   helpfile <- eval(call, envir = parent.frame())
   if (length(helpfile) == 0)
      browseURL(paste0("http://127.0.0.1:", .rs.httpdPort(), "/library/", pkgName, "/html/00Index.html"))
   else 
      print(helpfile)
})

.rs.addFunction("showHelpTopic", function(topic, package)
{
   call <- .rs.makeHelpCall(topic, package)
   print(eval(call, envir = parent.frame()))
})

.rs.addJsonRpcHandler("search", function(query)
{
   # first, check and see if we can get an exact match
   exactMatch <- help(query, help_type = "html")
   if (length(exactMatch) == 1)
   {
      print(exactMatch)
      return()
   }
   
   # if that failed, then we'll do an explicit search
   # if the search term is not a valid regular expression, then escape it
   status <- .rs.tryCatch(grep(query, "", perl = TRUE))
   if (inherits(status, "error"))
      query <- .rs.escapeForRegex(query)
   
   fmt <- "help/doc/html/Search?pattern=%s&title=1&keyword=1&alias=1"
   sprintf(fmt, utils::URLencode(query, reserved = TRUE))
})

.rs.addFunction("followHelpTopic", function(pkg, topic)
{
   tryCatch({
      # first look in the specified package
      file <- utils::help(topic, package = (pkg), help_type = "text", try.all.packages = FALSE)

      # TODO: copy behaviour from utils:::str2logical()
      linksToTopics <- identical(Sys.getenv("_R_HELP_LINKS_TO_TOPICS_", "TRUE"), "TRUE")
      
      # check if topic.Rd exist 
      if (!length(file) && linksToTopics) {
         helppath <- system.file("help", package = pkg)
         if (nzchar(helppath)) {
            contents <- readRDS(sub("/help$", "/Meta/Rd.rds", helppath, fixed = FALSE))
            helpfiles <- sub("\\.[Rr]d$", "", contents$File)
            if (topic %in% helpfiles) file <- file.path(helppath, topic)
         }
      }

      # next, search for topic in all installed packages
      if (!length(file)) {
         file <- utils::help(topic, help_type = "text", try.all.packages = TRUE)
      }

      as.character(file)

   }, error = function(e) character())
   
})

.rs.addJsonRpcHandler("follow_help_topic", function(url)
{
   rx <- "^.*/help/library/([^/]*)/help/(.*)$"
   pkg <- sub(rx, "\\1", url)
   topic <- utils::URLdecode(sub(rx, "\\2", url))

   .rs.followHelpTopic(pkg = pkg, topic = topic)
})

.rs.addFunction("RdLoadMacros", function(file)
{
   maybePackageDir <- dirname(dirname(file))
   if (file.exists(file.path(maybePackageDir, "DESCRIPTION")) ||
       file.exists(file.path(maybePackageDir, "DESCRIPTION.in")))
   {
      # NOTE: ?loadPkgRdMacros has:
      #
      #   loadPkgRdMacros loads the system Rd macros by default
      #
      # so it shouldn't be necessary to load system macros ourselves here
      tools::loadPkgRdMacros(maybePackageDir)
   }
   else
   {
      rMacroPath <- file.path(R.home("share"), "Rd/macros/system.Rd")
      tools::loadRdMacros(rMacroPath)
   }
})

.rs.addFunction("Rd2HTML", function(file, package = "")
{
   tf <- tempfile(); on.exit(unlink(tf))
   macros <- .rs.RdLoadMacros(file)
   tools::Rd2HTML(file, out = tf, package = package, macros = macros, dynamic = TRUE)
   lines <- readLines(tf, warn = FALSE)
   lines <- sub("R Documentation</td></tr></table>", "(preview) R Documentation</td></tr></table>", lines)
   if (nzchar(package))
   {
      # replace with "dev-figure" and parameters so that the server 
      # can look for figures in `man/` of the dev package
      lines <- sub('img src="figures/([^"]*)"', sprintf('img src="dev-figure?pkg=%s&figure=\\1"', package), lines)

      # add ?dev=<topic>
      lines <- gsub('a href="../../([^/]*/help/)([^/]*)">', 'a href="/library/\\1\\2?dev=\\2">', lines)
   }
   
   paste(lines, collapse = "\n")
})
