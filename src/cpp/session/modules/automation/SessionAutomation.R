#
# SessionAutomation.R
#
# Copyright (C) 2024 by Posit Software, PBC
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

# Global handlers for WebSocket messages and responses.
.rs.setVar("automation.callbacks", new.env(parent = emptyenv()))
.rs.setVar("automation.messageId", 0L)
.rs.setVar("automation.responses", new.env(parent = emptyenv()))

# Global state tracking the active client + session ID.
.rs.setVar("automation.client", NULL)
.rs.setVar("automation.targetId", NULL)
.rs.setVar("automation.sessionId", NULL)

# Global variable for tracking the active automation agent.
.rs.setVar("automation.agentProcess", NULL)


.rs.addFunction("automation.httrGet", function(url)
{
   httr::GET(url, config = httr::timeout(1))
})

.rs.addFunction("automation.installRequiredPackages", function()
{
   packages <- c("here", "httr", "later", "processx", "ps", "styler", "usethis", "websocket", "withr", "xml2")
   pkgLocs <- find.package(packages, quiet = TRUE)
   if (length(packages) == length(pkgLocs))
      return()
   
   writeLines("==> Installing Packages")
   for (package in packages)
   {
      if (!requireNamespace(package, quietly = TRUE))
      {
         install.packages(package)
         loadNamespace(package)
      }
   }
})

.rs.addFunction("automation.onMessage", function(event)
{
   # Small bit of indirection to make hot reloading easier.
   .rs.automation.onMessageImpl(event)
})

.rs.addFunction("automation.onMessageImpl", function(event)
{
   # Get the data associated with this request.
   data <- .rs.fromJSON(event[["data"]])
   
   # TODO: Check for an error status.
   
   # TODO: Handle events. Right now we just ignore them.
   if (!is.null(data[["method"]]))
      return()
   
   # Check for a callback associated with this id.
   id <- data[["id"]]
   if (is.null(id)) {
      print(event)
      warning("response missing 'id' parameter")
      return()
   }
   
   # Retrieve the stored callback.
   callback <- .rs.automation.callbacks[[as.character(id)]]
   if (is.null(callback)) {
      warning("no callback registered for response with id '", id, "'")
      return()
   }
   
   tryCatch(
      
      # Invoke the callback.
      callback(data),
      
      # Treat errors as warnings.
      error = function(cnd) {
         warning(conditionMessage(cnd))
      },
      
      # Remove the callback when we're done.
      finally = {
         rm(list = as.character(id), envir = .rs.automation.callbacks)
      }
      
   )
   
})

.rs.addFunction("automation.onError", function(event)
{
   print(event)
})

.rs.addFunction("automation.onClose", function(event)
{
   # TODO: Any cleanup we need to do?
})

.rs.addFunction("automation.sendRequest", function(socket, method, params, callback = NULL)
{
   # Handle lazy callers.
   if (is.function(params) && is.null(callback))
   {
      callback <- params
      params <- list()
   }
   
   # Convert jsobject to character.
   for (i in seq_along(params))
   {
      if (inherits(params[[i]], "jsObject"))
      {
         params[[i]] <- as.character(unclass(params[[i]]))
      }
   }
   
   # Generate an id for this request.
   id <- .rs.automation.messageId
   .rs.setVar("automation.messageId", .rs.automation.messageId + 1L)
   
   # Register a callback for this message id.
   assign(as.character(id), callback, envir = .rs.automation.callbacks)
   
   # Generate the request.
   request <- list(
      id     = id,
      method = method,
      params = params
   )
   
   # Attach a session ID if one is available.
   if (!is.null(.rs.automation.sessionId))
      request[["sessionId"]] <- .rs.automation.sessionId
   
   # Fire it off.
   json <- .rs.toJSON(request, unbox = TRUE)
   socket$send(json)
   
   # Return the id.
   invisible(id)
})

.rs.addFunction("automation.sendSynchronousRequest", function(socket, method, params = list())
{
   # Drop NULL parameters.
   params <- params[!vapply(params, is.null, FUN.VALUE = logical(1))]
   
   # Make sure parameters are named.
   names(params) <- .rs.nullCoalesce(names(params), rep.int("", length(params)))
   
   # Send the request.
   response <- NULL
   callback <- function(response)
   {
      response <<- response
   }
   
   .rs.automation.sendRequest(socket, method, params, callback)
   
   # Wait for a response.
   .rs.waitUntil("automation response received", function()
   {
      !is.null(response)
   }, waitTimeSecs = 0.1)
   
   # Handle errors.
   error <- response[["error"]]
   if (!is.null(error))
   {
      fmt <- "execution of '%s' failed: %s [error code %i]"
      msg <- sprintf(fmt, method, error[["message"]], error[["code"]])
      stop(msg, call. = FALSE)
   }
   
   # Return the received data.
   response[["result"]]
   
})

.rs.addFunction("automation.applicationPathServer", function()
{
   if (.rs.platform.isMacos)
   {
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
   }
   else if (.rs.platform.isWindows)
   {
      "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"
   }
   else
   {
      Sys.which("chromium")
   }
})

.rs.addFunction("automation.applicationPathDesktop", function()
{
   # Assume that the RStudio Desktop instance is the parent of
   # the running R session.
   ps::ps_exe(ps::ps_parent())
})

.rs.addFunction("automation.applicationPath", function(mode)
{
   switch(
      mode,
      server  = .rs.automation.applicationPathServer(),
      desktop = .rs.automation.applicationPathDesktop(),
   )
})

.rs.addFunction("automation.killAutomationServer", function(...)
{
   procs <- subset(ps::ps(), name == "rserver")
   for (i in seq_len(nrow(procs)))
   {
      proc <- procs[i, ]
      conns <- ps::ps_connections(proc$ps_handle[[1L]])
      if (8788L %in% conns$lport)
      {
         handle <- ps::ps_handle(pid = proc$pid)
         return(ps::ps_kill(handle))
      }
   }
})

.rs.addFunction("automation.ensureRunningServerInstance", function()
{
   # Check and see if we already have an rserver instance listening.
   procs <- subset(ps::ps(), name == "rserver")
   for (i in seq_len(nrow(procs)))
   {
      proc <- procs[i, ]
      conns <- ps::ps_connections(proc$ps_handle[[1L]])
      if (8788L %in% conns$lport)
         return(TRUE)
   }
   
   # See if we can figure out how the parent was launched, and use that
   # to infer whether we can launch the automation helper.
   parentHandle <- ps::ps_parent()
   parentEnv <- ps::ps_environ(parentHandle)
   parentPwd <- parentEnv[["PWD"]]
   automationScript <- file.path(parentPwd, "rserver-automation")
   if (!file.exists(automationScript))
      stop("rserver does not appear to be running on port 8788")
   
   message("-- Starting rserver-automation ...")
   withr::with_dir(parentPwd, system2(automationScript, wait = FALSE))
   
   # Kill the process on exit
   reg.finalizer(globalenv(), .rs.automation.killAutomationServer, onexit = TRUE)
   
   
})

.rs.addFunction("automation.initialize", function(appPath = NULL,
                                                  mode = c("server", "desktop"),
                                                  port = NULL)
{
   # Make sure all requisite packages are installed.
   .rs.automation.installRequiredPackages()
   
   # Resolve arguments.
   mode <- match.arg(mode)
   port <- .rs.nullCoalesce(port, if (mode == "server") 9999L else 9998L)
   
   # Ensure that we have a running rserver instance.
   if (mode == "server")
      .rs.automation.ensureRunningServerInstance()
   
   # Check for an existing session we can attach to.
   baseUrl <- sprintf("http://localhost:%i", port)
   jsonVersionUrl <- file.path(baseUrl, "json/version")
   response <- .rs.tryCatch(.rs.automation.httrGet(jsonVersionUrl))
   if (!inherits(response, "error"))
      return(.rs.automation.attach(baseUrl, mode))
   
   # No existing session; start a new one and attach to it.
   appPath <- .rs.nullCoalesce(appPath, {
      defaultAppPath <- .rs.automation.applicationPath(mode)
      Sys.getenv("RSTUDIO_AUTOMATION_EXE", unset = defaultAppPath)
   })
   
   # Set up environment for newly-launched RStudio instance.
   envVars <- as.list(Sys.getenv())
   
   # Unset any RStudio-specific environment variables, so that this looks
   # like a "fresh" RStudio session.
   rstudioEnvVars <- grep("^(?:RS|RSTUDIO)_", names(envVars))
   envVars[rstudioEnvVars] <- list(NULL)
   envVars["R_SESSION_TMPDIR"] <- list(NULL)
   
   # Make sure the automation server uses the same R session executable.
   envVars[["RSTUDIO_WHICH_R"]] <- if (.rs.platform.isWindows)
      file.path(R.home("bin"), "R.exe")
   else
      file.path(R.home("bin"), "R")
   
   # Ensure that the new RStudio instance uses temporary storage.
   stateDir <- tempfile("rstudio-automation-state-")
   dir.create(stateDir, recursive = TRUE)
   
   configHome <- file.path(stateDir, "config-home")
   configDir  <- file.path(stateDir, "config-dir")
   dataHome   <- file.path(stateDir, "data-home")
   
   envVars[["RSTUDIO_CONFIG_HOME"]] <- configHome
   envVars[["RSTUDIO_CONFIG_DIR"]]  <- configDir
   envVars[["RSTUDIO_DATA_HOME"]]   <- dataHome
   
   # Create a default JSON configuration file.
   config <- list(
      auto_save_on_idle = "none",
      continue_comments_on_newline = FALSE,
      save_workspace = "never",
      windows_terminal_shell = "win-cmd"
   )
   
   configJson <- .rs.toJSON(config, unbox = TRUE)
   configPath <- file.path(configHome, "rstudio-prefs.json")
   .rs.ensureDirectory(dirname(configPath))
   writeLines(configJson, con = configPath)
   
   # Avoid displaying modal dialogs on startup.
   envVars[["RS_NO_SPLASH"]] <- "1"
   envVars[["RS_CRASH_HANDLER_PROMPT"]] <- "false"
   envVars[["RSTUDIO_DISABLE_CHECK_FOR_UPDATES"]] <- "1"
   
   # Avoid crashing on arm64 Linux.
   envVars[["RSTUDIO_QUERY_FONTS"]] <- "0"
   
   # Build argument list.
   # https://github.com/GoogleChrome/chrome-launcher/blob/main/docs/chrome-flags-for-tools.md
   
   # If it looks like we're running with Electron (that is, a development build)
   # then we need to include the path to the appropriate working directory.
   baseArgs <- if (grepl("electron", basename(appPath), ignore.case = TRUE))
   {
      ps::ps_cwd(ps::ps_parent())
   }
   
   args <- c(
      baseArgs,
      sprintf("--remote-debugging-port=%i", port),
      sprintf("--user-data-dir=%s", tempdir()),
      if (mode == "desktop") c("--automation-agent"),
      if (mode == "server") c(
         "--no-default-browser-check",
         "--no-first-run",
         "--disable-extensions",
         "--disable-features=PrivacySandboxSettings4",
         "http://localhost:8788"
      )
   )
   
   # Start up RStudio.
   process <- withr::with_envvar(envVars, {
      processx::process$new(appPath, args)
   })
   
   # Wait until the process is running.
   while (process$get_status() != "running")
   {
      status <- process$get_exit_status()
      if (!is.null(status))
      {
         fmt <- "RStudio agent exited unexpectedly [error code %i]"
         stop(sprintf(fmt, status))
      }
      
      Sys.sleep(0.1)
   }
   
   # Start pinging the Chromium HTTP server.
   response <- NULL
   .rs.waitUntil("Chromium HTTP server available", function()
   {
      response <<- .rs.tryCatch(.rs.automation.httrGet(jsonVersionUrl))
      !inherits(response, "error")
   })
   
   # We have a live process; save it so we can interact with it later.
   .rs.setVar("automation.agentProcess", process)
   
   # The session is ready; attach now.
   jsonResponse <- .rs.fromJSON(rawToChar(response$content))
   .rs.automation.attach(baseUrl, mode, jsonResponse$webSocketDebuggerUrl)
   
})

.rs.addFunction("automation.attach", function(baseUrl, mode, url = NULL)
{
   # Clear a previous session ID if necessary.
   .rs.setVar("automation.client", NULL)
   .rs.setVar("automation.targetId", NULL)
   .rs.setVar("automation.sessionId", NULL)
   
   # Get the websocket debugger URL.
   url <- .rs.nullCoalesce(url, {
      jsonVersionUrl <- file.path(baseUrl, "json/version")
      response <- .rs.automation.httrGet(jsonVersionUrl)
      jsonResponse <- .rs.fromJSON(rawToChar(response$content))
      jsonResponse$webSocketDebuggerUrl
   })
   
   # Create the websocket.
   socket <- websocket::WebSocket$new(url)
   
   # Handle websocket messages.
   socket$onMessage(.rs.automation.onMessage)
   socket$onError(.rs.automation.onError)
   socket$onClose(.rs.automation.onClose)
   
   # Wait until the socket is open.
   .rs.waitUntil("websocket open", function()
   {
      socket$readyState() == 1L
   }, waitTimeSecs = 0.1)
   
   # Create the automation client.
   client <- .rs.automation.createClient(socket)
   
   # Save a reference to the websocket.
   client$socket <- socket
   
   # Find and record the active session id.
   .rs.automation.attachToSession(client, mode)
   
   # Wait until the Console is available.
   document <- client$DOM.getDocument(depth = 0L)
   .rs.waitUntil("Console input available", function()
   {
      consoleNode <- client$DOM.querySelector(document$root$nodeId, "#rstudio_console_input")
      consoleNode$nodeId != 0L
   })
   
   # Return the client.
   client
   
})

.rs.addFunction("automation.attachToSession", function(client, mode)
{
   callback <- switch(mode,
                      desktop = .rs.automation.attachToSessionDesktop,
                      server  = .rs.automation.attachToSessionServer
   )
   
   for (i in 1:10)
   {
      sessionId <- tryCatch(callback(client), error = identity)
      if (is.character(sessionId))
         return(sessionId)
      
      Sys.sleep(1)
   }
   
   stop("Couldn't attach to session")
})

.rs.addFunction("automation.attachToSessionDesktop", function(client)
{
   # Try to get the available targets.
   targets <- .rs.tryCatch(client$Target.getTargets())
   if (inherits(targets, "error"))
      return(NULL)
   
   # Check for the RStudio window.
   currentTarget <- Find(function(target) target$title == "RStudio", targets$targetInfos)
   if (is.null(currentTarget))
      return(NULL)
   
   # Attach to this target.
   currentTargetId <- currentTarget$targetId
   response <- client$Target.attachToTarget(targetId = currentTargetId, flatten = TRUE)
   sessionId <- response$sessionId
   
   # Update our global variables.
   .rs.setVar("automation.client", client)
   .rs.setVar("automation.targetId", currentTargetId)
   .rs.setVar("automation.sessionId", sessionId)
   
   # Return the discovered session ID.
   sessionId
})

.rs.addFunction("automation.attachToSessionServer", function(client)
{
   # Try to get the available targets.
   targets <- .rs.tryCatch(client$Target.getTargets())
   if (inherits(targets, "error"))
      return(NULL)
   
   # If we don't have any targets, then create a new session.
   if (length(targets) == 0L)
   {
      client$Target.createTarget(url = "about:blank")
      targets <- .rs.tryCatch(client$Target.getTargets())
      if (inherits(targets, "error"))
         return(NULL)
   }
   
   # Find a page.
   currentTarget <- Find(function(target) target$type == "page", targets$targetInfos)
   if (is.null(currentTarget))
      return(NULL)
   
   # Attach to this target.
   currentTargetId <- currentTarget$targetId
   response <- client$Target.attachToTarget(targetId = currentTargetId, flatten = TRUE)
   sessionId <- response$sessionId
   
   # Update our global variables.
   .rs.setVar("automation.client", client)
   .rs.setVar("automation.targetId", currentTargetId)
   .rs.setVar("automation.sessionId", sessionId)
   
   # TODO: Handle input of authentication credentials?
   # Should that happen here, or elsewhere?
   
   # Return the session id.
   sessionId
})

.rs.addFunction("automation.runImpl", function(projectRoot = getwd(),
                                               reportFile = NULL,
                                               automationMode = NULL)
{
   # Resolve the automation mode.
   automationMode <- .rs.automation.resolveMode(automationMode)
   
   # Move to the project root directory.
   owd <- setwd(projectRoot)
   on.exit(setwd(owd), add = TRUE)
   
   # Move to the automation directory.
   withr::local_dir("src/cpp/tests/automation")
   
   # Set up automation mode.
   withr::local_envvar(RSTUDIO_AUTOMATION_MODE = automationMode)
   
   # Figure out where we're writing our test results.
   reportFile <- .rs.nullCoalesce(reportFile, {
      tempfile("junit-", fileext = ".xml")
   })
   
   # Create a junit-style reporter, for Jenkins.
   junitReporter <- testthat::JunitReporter$new(file = reportFile)
   
   # Create a regular progress reporter.
   progressReporter <- testthat::ProgressReporter$new()
   
   # Combine with the default reporter.
   multiReporter <- testthat::MultiReporter$new(
      reporters = list(
         progressReporter,
         junitReporter
      )
   )
   
   # Clear the console, and show a header that indicates we're about to run automation tests.
   invisible(.rs.api.executeCommand("consoleClear"))
   writeLines(c("", "==> Running RStudio automation tests...", ""))
   
   # Run tests.
   testthat::test_dir(
      path = "testthat",
      reporter = multiReporter,
      stop_on_failure = FALSE,
      stop_on_warning = FALSE
   )
   
})

.rs.addFunction("automation.run", function(projectRoot = NULL,
                                           reportFile = NULL,
                                           automationMode = NULL,
                                           gitRef = NULL)
{
   on.exit(.rs.automation.onFinishedRunningAutomation(), add = TRUE)
   
   # Resolve the project root. Note that test are expected to be found
   # within the 'src/cpp/session/automation' sub-directory of this path.
   projectRoot <- .rs.nullCoalesce(projectRoot, {
      Sys.getenv("RSTUDIO_AUTOMATION_ROOT", unset = NA)
   })
   
   # Resolve the report file from session options if provided.
   reportFile <- .rs.nullCoalesce(reportFile, .rs.automation.reportFile())
   
   # If the path to a test directory was provided, use that.
   if (!is.na(projectRoot))
      return(.rs.automation.runImpl(projectRoot, reportFile, automationMode))
   
   # Otherwise, try to resolve and retrieve the automation tests
   # to be used based on the provided commit ref.
   projectRoot <- tempfile("rstudio-automation-")
   dir.create(projectRoot)
   owd <- setwd(projectRoot)
   on.exit(setwd(owd), add = TRUE)
   
   # Figure out the commit reference to use.
   gitRef <- .rs.nullCoalesce(gitRef, {
      productInfo <- .Call("rs_getProductInfo", PACKAGE = "(embedding)")
      .rs.nullCoalesce(productInfo$commit, "main")
   })
   
   # Retrieve test files.
   .rs.automation.retrieveTests(ref = gitRef)
   
   # Run automation tests with retrieved files.
   .rs.automation.runImpl(
      projectRoot = projectRoot,
      reportFile = reportFile,
      automationMode = automationMode
   )
})

.rs.addFunction("automation.retrieveTests", function(ref)
{
   # Retrieve the download URLs.
   envir <- new.env(parent = emptyenv())
   .rs.automation.listTestFiles("src/cpp/tests/automation", ref, envir)
   paths <- as.list.environment(envir, all.names = TRUE)
   storage.mode(paths) <- "character"
   
   # Make sure the requisite parent directories exist.
   parentDirs <- unique(dirname(names(paths)))
   for (parentDir in parentDirs)
      .rs.ensureDirectory(parentDir)
   
   # Download these URLs. Do this in parallel with curl if possible.
   # Fall back to the default R download machinery otherwise.
   if (nzchar(Sys.which("curl")))
   {
      curlConfig <- sprintf("url = \"%s\"\noutput = \"%s\"\n", paths, names(paths))
      curlConfigFile <- tempfile("curl-config-")
      on.exit(unlink(curlConfigFile), add = TRUE)
      writeLines(curlConfig, con = curlConfigFile)
      args <- c("-Z", "--config", shQuote(curlConfigFile))
      system2("curl", args)
   }
   else
   {
      .rs.enumerate(paths, function(path, url)
      {
         download.file(url = url, destfile = path)
      })
   }
})

.rs.addFunction("automation.listTestFiles", function(path, ref, envir)
{
   # Request the contents of this file / directory.
   fmt <- "https://api.github.com/repos/rstudio/rstudio/contents/%s?ref=%s"
   url <- sprintf(fmt, path, ref)
   
   response <- .rs.automation.httrGet(url)
   result <- httr::content(response, as = "parsed")
   
   # Iterate through the directory contents, and get download links.
   for (entry in result)
   {
      if (identical(entry$type, "file"))
      {
         assign(entry$path, entry$download_url, envir = envir)
      }
      else if (identical(entry$type, "dir"))
      {
         .rs.automation.listTestFiles(entry$path, ref, envir)
      }
   }
})

.rs.addFunction("automation.resolveMode", function(mode)
{
   .rs.nullCoalesce(mode, {
      defaultMode <- .Call("rs_rstudioProgramMode", PACKAGE = "(embedding)")
      Sys.getenv("RSTUDIO_AUTOMATION_MODE", unset = defaultMode)
   })
})

.rs.addFunction("automation.reportFile", function()
{
   .Call("rs_automationReportFile", PACKAGE = "(embedding)")
})

.rs.addFunction("automation.onFinishedRunningAutomation", function()
{
   isJenkins <- Sys.getenv("JENKINS_URL", unset = NA)
   if (!is.na(isJenkins))
      quit(status = 0L)
   
   message("- Automated tests have finished running.")
   message("- You can now close this instance of RStudio.")
})

.rs.addFunction("automation.isClientValid", function(client)
{
   object <- client$socket$.__enclos_env__$private$wsObj
   !.rs.isNullExternalPointer(object)
})
