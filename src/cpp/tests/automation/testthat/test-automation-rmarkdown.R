
library(testthat)

self <- remote <- .rs.automation.newRemote()
withr::defer(.rs.automation.deleteRemote())

test_that("the warn option is preserved when running chunks", {
   
   contents <- .rs.heredoc('
      ---
      title: Chunk Warnings
      ---
      
      ```{r warning=TRUE}
      # check current option
      getOption("warn")
      # setting a global option
      options(warn = 2)
      ```
   ')
   
   remote$consoleExecuteExpr({ options(warn = 0) })
   remote$consoleExecuteExpr({ getOption("warn") })
   output <- remote$consoleOutput()
   expect_equal(tail(output, n = 1L), "[1] 0")
   
   id <- remote$documentOpen(".Rmd", contents)
   editor <- remote$editorGetInstance()
   editor$gotoLine(6)
   remote$keyboardExecute("<Ctrl + Shift + Enter>")
   remote$consoleExecuteExpr({ getOption("warn") })
   output <- remote$consoleOutput()
   expect_equal(tail(output, n = 1L), "[1] 2")
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
   
})

test_that("the expected chunk widgets show for multiple chunks", {

   contents <- .rs.heredoc('
      ---
      title: "Chunk widgets"
      ---
      
      ```{r setup, include=FALSE}
      knitr::opts_chunk$set(echo = TRUE)
      ```
      
      ## R Markdown
      
      This is an R Markdown document.
      
      ```{r cars}
      summary(cars)
      ```
      
      ## Including Plots
      
      You can also embed plots, for example:
      
      ```{r pressure, echo=FALSE}
      plot(pressure)
      ```
      
      The end.
   ')
   
   id <- remote$documentOpen(".Rmd", contents)
   
   jsChunkOptionWidgets <- remote$jsObjectsViaSelector(".rstudio_modify_chunk")
   jsChunkPreviewWidgets <- remote$jsObjectsViaSelector(".rstudio_preview_chunk")
   jsChunkRunWidgets <- remote$jsObjectsViaSelector(".rstudio_run_chunk")
   
   expect_equal(length(jsChunkOptionWidgets), 3)
   expect_equal(length(jsChunkPreviewWidgets), 3)
   expect_equal(length(jsChunkRunWidgets), 3)
   
   # setup chunk's "preview" widget should be aria-hidden and display:none
   expect_true(.rs.automation.tools.isAriaHidden(jsChunkPreviewWidgets[[1]]))
   expect_equal(jsChunkPreviewWidgets[[1]]$style$display, "none")
   
   # all others should not be hidden
   checkWidgetVisible <- function(widget) {
      expect_false(.rs.automation.tools.isAriaHidden(widget))
      expect_false(widget$style$display == "none")
   }
   lapply(jsChunkPreviewWidgets[2:3], checkWidgetVisible)
   lapply(jsChunkOptionWidgets, checkWidgetVisible)
   lapply(jsChunkRunWidgets, checkWidgetVisible)
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})

test_that("can cancel switching to visual editor", {
   contents <- .rs.heredoc('
      ---
      title: "Visual Mode Denied"
      ---
      
      ## R Markdown
      
      This is an R Markdown document.
   ')
   
   remote$consoleExecute(".rs.writeUserState(\"visual_mode_confirmed\", FALSE)")
   remote$consoleExecute(".rs.writeUserPref(\"visual_markdown_editing_is_default\", FALSE)")
   
   id <- remote$documentOpen(".Rmd", contents)
   
   sourceModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_off")[[1]]
   visualModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_on")[[1]]
   
   # do this twice to also check that the "switching to visual mode" dialog appears
   # the second time (i.e. that it doesn't set the state to prevent its display when
   # it is canceled)
   for (i in 1:2) {
      expect_equal(sourceModeToggle$ariaPressed, "true")
      expect_equal(visualModeToggle$ariaPressed, "false")
      
      remote$domClickElement(".rstudio_visual_md_on")
      .rs.waitUntil("The switching to visual mode first time dialog appears", function() {
         tryCatch({
            cancelBtn <- remote$jsObjectViaSelector("#rstudio_dlg_cancel")
            grepl("Cancel", cancelBtn$innerText)
         }, error = function(e) FALSE)
      })
      remote$domClickElement("#rstudio_dlg_cancel")
      expect_equal(sourceModeToggle$ariaPressed, "true")
      expect_equal(visualModeToggle$ariaPressed, "false")
   }
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})

test_that("can switch to visual editor and back to source editor", {
   contents <- .rs.heredoc('
      ---
      title: "Visual Mode"
      ---
      
      ## R Markdown
      
      This is an R Markdown document.
   ')
   
   remote$consoleExecute(".rs.writeUserState(\"visual_mode_confirmed\", FALSE)")
   remote$consoleExecute(".rs.writeUserPref(\"visual_markdown_editing_is_default\", FALSE)")
   
   id <- remote$documentOpen(".Rmd", contents)
   
   sourceModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_off")[[1]]
   visualModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_on")[[1]]
   
   # do this twice to check that the "switching to visual mode" dialog doesn't appear
   # the second time
   for (i in 1:2) {
      expect_equal(sourceModeToggle$ariaPressed, "true")
      expect_equal(visualModeToggle$ariaPressed, "false")
      
      remote$domClickElement(".rstudio_visual_md_on")
      
      if (i == 1)
      {
        .rs.waitUntil("The switching to visual mode first time dialog appears", function() {
           tryCatch({
              okBtn <- remote$jsObjectViaSelector("#rstudio_dlg_ok")
              grepl("Use Visual Mode", okBtn$innerText)
            }, error = function(e) FALSE)
         })
         remote$domClickElement("#rstudio_dlg_ok")
      }
      
      .rs.waitUntil("Visual Editor appears", function() {
         tryCatch({
            visualEditor <- remote$jsObjectViaSelector(".ProseMirror")
            visualEditor$contentEditable
         }, error = function(e) FALSE)
      })
      
      expect_equal(sourceModeToggle$ariaPressed, "false")
      expect_equal(visualModeToggle$ariaPressed, "true")
      
      # back to source mode
      remote$domClickElement(".rstudio_visual_md_off")
   }
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})

test_that("visual editor welcome dialog displays again if don't show again is unchecked", {
   contents <- .rs.heredoc('
      ---
      title: "Visual Mode"
      ---
      
      ## R Markdown
      
      This is an R Markdown document.
   ')
   
   remote$consoleExecute(".rs.writeUserState(\"visual_mode_confirmed\", FALSE)")
   remote$consoleExecute(".rs.writeUserPref(\"visual_markdown_editing_is_default\", FALSE)")
   
   id <- remote$documentOpen(".Rmd", contents)
   
   sourceModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_off")[[1]]
   visualModeToggle <- remote$jsObjectsViaSelector(".rstudio_visual_md_on")[[1]]
   
   # do this twice to check that the "switching to visual mode" dialog appears second time
   for (i in 1:2) {
      expect_equal(sourceModeToggle$ariaPressed, "true")
      expect_equal(visualModeToggle$ariaPressed, "false")
      
      remote$domClickElement(".rstudio_visual_md_on")
      
      .rs.waitUntil("The switching to visual mode first time dialog appears", function() {
         tryCatch({
            okBtn <- remote$jsObjectViaSelector("#rstudio_dlg_ok")
            grepl("Use Visual Mode", okBtn$innerText)
         }, error = function(e) FALSE)
      })
      
      # uncheck "Don't show again"
      remote$domClickElement(".gwt-DialogBox-ModalDialog input[type=\"checkbox\"]")
      remote$domClickElement("#rstudio_dlg_ok")
      
      .rs.waitUntil("Visual Editor appears", function() {
         tryCatch({
           visualEditor <- remote$jsObjectViaSelector(".ProseMirror")
           visualEditor$contentEditable
         }, error = function(e) FALSE)
      })
      
      expect_equal(sourceModeToggle$ariaPressed, "false")
      expect_equal(visualModeToggle$ariaPressed, "true")
      
      # back to source mode
      remote$domClickElement(".rstudio_visual_md_off")
   }
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})

test_that("displaying and closing chunk options popup doesn't modify settings", {
   
   contents <- .rs.heredoc('
      ---
      title: "The Title"
      ---
      
      ```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}
      print("one")
      ```
      
      ```{r}
      print("two")
      ```
       
      The end.
   ')
   
   id <- remote$documentOpen(".Rmd", contents)
   editor <- remote$editorGetInstance()
   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")
   
   checkChunkOption <- function(line, expected, widget)
   {
      original <- editor$session$getLine(line)
      expect_equal(original, expected)
      remote$domClickElementByNodeId(widget)
      remote$keyboardExecute("<Escape>")
      updated <- editor$session$getLine(line)
      expect_equal(original, updated)
   }
   
   checkChunkOption(
      8,
      "```{r}",
      chunkOptionWidgetIds[[2]])

   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")

   checkChunkOption(
      4,
      "```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}",
      chunkOptionWidgetIds[[1]])
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})

test_that("displaying chunk options popup and applying without making changes doesn't modify settings", {
   
   contents <- .rs.heredoc('
      ---
      title: "The Title"
      ---
      
      ```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}
      print("one")
      ```
      
      ```{r}
      print("two")
      ```
      
      ```{r fig.cap = "a caption"}
      ```
      
      The end.
   ')
   
   id <- remote$documentOpen(".Rmd", contents)
   editor <- remote$editorGetInstance()
   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")
   
   checkChunkOption <- function(line, expected, widget)
   {
      original <- editor$session$getLine(line)
      expect_equal(original, expected)
      remote$domClickElementByNodeId(widget)
      remote$domClickElement("#rstudio_chunk_opt_apply")
      updated <- editor$session$getLine(line)
      expect_equal(original, updated)
   }
   
   checkChunkOption(
      8,
      "```{r}",
      chunkOptionWidgetIds[[2]])

   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")

   checkChunkOption(
      4,
      "```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}",
      chunkOptionWidgetIds[[1]])
   # chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")
   # checkChunkOption(
   #    12,
   #    "```{r fig.cap = \"a caption\"}", # https://github.com/rstudio/rstudio/issues/6829 TODO
   #    chunkOptionWidgetIds[[3]])
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")
})


test_that("reverting chunk option changes restores original options ", {
   
   contents <- .rs.heredoc('
      ---
      title: "The Title"
      ---
      
      ```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}
      print("one")
      ```
      
      ```{r}
      print("two")
      ```
       
      The end.
   ')
   
   id <- remote$documentOpen(".Rmd", contents)
   editor <- remote$editorGetInstance()
   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")
   
   checkChunkOption <- function(line, expected, nodeId)
   {
      original <- editor$session$getLine(line)
      expect_equal(original, expected)
      remote$domClickElementByNodeId(nodeId)
      remote$domClickElement("#rstudio_chunk_opt_warnings")
      remote$domClickElement("#rstudio_chunk_opt_messages")
      remote$domClickElement("#rstudio_chunk_opt_warnings")
      remote$domClickElement("#rstudio_chunk_opt_messages")
      remote$jsObjectViaSelector("#rstudio_chunk_opt_name")$focus()
      remote$keyboardExecute("abcdefg hijklmnop 12345")
      remote$domClickElement("#rstudio_chunk_opt_tables")
      remote$domClickElement("#rstudio_chunk_opt_figuresize")
      remote$domClickElement("#rstudio_chunk_opt_revert")
      updated <- editor$session$getLine(line)
      expect_equal(original, updated)
   }
   
   checkChunkOption(
      8,
      "```{r}",
      chunkOptionWidgetIds[[2]])
   chunkOptionWidgetIds <- remote$domGetNodeIds(".rstudio_modify_chunk")
   checkChunkOption(
      4,
      "```{r one, fig.height=4, fig.width=3, message=FALSE, warning=TRUE, paged.print=TRUE}",
      chunkOptionWidgetIds[[1]])
   
   remote$documentClose()
   remote$keyboardExecute("<Ctrl + L>")

})

# https://github.com/rstudio/rstudio/issues/6829
# TODO: uncomment when issue is resolved
# test_that("modifying chunk options via UI doesn't mess up other options", {
   
#    contents <- .rs.heredoc('
#       ---
#       title: "Issue 6829"
#       ---
      
#       ```{r fig.cap = "a caption"}
#       print("Hello")
#       ```
   
#       The end.
#    ')
   
#    id <- remote$documentOpen(".Rmd", contents)
#    editor <- remote$editorGetInstance()
   
#    original <- editor$session$getLine(4)
   
#    remote$domClickElement(".rstudio_modify_chunk")
#    remote$domClickElement("#rstudio_chunk_opt_warnings")
#    remote$domClickElement("#rstudio_chunk_opt_messages")
#    remote$keyboardExecute("<Escape>")
#    expect_equal(original, editor$session$getLine(4))
#    remote$documentClose()
#    remote$keyboardExecute("<Ctrl + L>")
# })

