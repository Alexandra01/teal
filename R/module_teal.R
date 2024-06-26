# This module is the main teal module that puts everything together.

#' `teal` main app module
#'
#' This is the main `teal` app that puts everything together.
#'
#' It displays the splash UI which is used to fetch the data, possibly
#' prompting for a password input to fetch the data. Once the data is ready,
#' the splash screen is replaced by the actual `teal` UI that is tabsetted and
#' has a filter panel with `datanames` that are relevant for the current tab.
#' Nested tabs are possible, but we limit it to two nesting levels for reasons
#' of clarity of the UI.
#'
#' The splash screen functionality can also be used
#' for non-delayed data which takes time to load into memory, avoiding
#' `shiny` session timeouts.
#'
#' Server evaluates the `teal_data_rv` (delayed data mechanism) and creates the
#' `datasets` object that is shared across modules.
#' Once it is ready and non-`NULL`, the splash screen is replaced by the
#' main `teal` UI that depends on the data.
#' The currently active tab is tracked and the right filter panel
#' updates the displayed datasets to filter for according to the active `datanames`
#' of the tab.
#'
#' @name module_teal
#'
#' @inheritParams module_teal_with_splash
#'
#' @param splash_ui (`shiny.tag`) UI to display initially,
#'   can be a splash screen or a `shiny` module UI. For the latter, see
#'   [init()] about how to call the corresponding server function.
#'
#' @param teal_data_rv (`reactive`)
#'   returns the `teal_data`, only evaluated once, `NULL` value is ignored
#'
#' @return
#' Returns a `reactive` expression which returns the currently active module.
#'
#' @keywords internal
#'
NULL

#' @rdname module_teal
ui_teal <- function(id,
                    splash_ui = tags$h2("Starting the Teal App"),
                    title = build_app_title(),
                    header = tags$p(),
                    footer = tags$p()) {
  checkmate::assert_character(id, max.len = 1, any.missing = FALSE)

  checkmate::assert_multi_class(splash_ui, c("shiny.tag", "shiny.tag.list", "html"))

  if (is.character(title)) {
    title <- build_app_title(title)
  } else {
    validate_app_title_tag(title)
  }

  checkmate::assert(
    .var.name = "header",
    checkmate::check_string(header),
    checkmate::check_multi_class(header, c("shiny.tag", "shiny.tag.list", "html"))
  )
  if (checkmate::test_string(header)) {
    header <- tags$p(header)
  }

  checkmate::assert(
    .var.name = "footer",
    checkmate::check_string(footer),
    checkmate::check_multi_class(footer, c("shiny.tag", "shiny.tag.list", "html"))
  )
  if (checkmate::test_string(footer)) {
    footer <- tags$p(footer)
  }

  ns <- NS(id)

  # Once the data is loaded, we will remove this element and add the real teal UI instead
  splash_ui <- tags$div(
    # id so we can remove the splash screen once ready, which is the first child of this container
    id = ns("main_ui_container"),
    # we put it into a div, so it can easily be removed as a whole, also when it is a tagList (and not
    # just the first item of the tagList)
    tags$div(splash_ui)
  )

  # show busy icon when `shiny` session is busy computing stuff
  # based on https://stackoverflow.com/questions/17325521/r-shiny-display-loading-message-while-function-is-running/22475216#22475216 # nolint: line_length.
  shiny_busy_message_panel <- conditionalPanel(
    condition = "(($('html').hasClass('shiny-busy')) && (document.getElementById('shiny-notification-panel') == null))", # nolint: line_length.
    tags$div(
      icon("arrows-rotate", "spin fa-spin"),
      "Computing ...",
      # CSS defined in `custom.css`
      class = "shinybusymessage"
    )
  )

  fluidPage(
    title = title,
    theme = get_teal_bs_theme(),
    include_teal_css_js(),
    tags$header(header),
    tags$hr(class = "my-2"),
    shiny_busy_message_panel,
    splash_ui,
    tags$hr(),
    tags$footer(
      tags$div(
        footer,
        teal.widgets::verbatim_popup_ui(ns("sessionInfo"), "Session Info", type = "link"),
        br(),
        downloadLink(ns("lockFile"), "Download .lock file"),
        textOutput(ns("identifier"))
      )
    )
  )
}


#' @rdname module_teal
srv_teal <- function(id, modules, teal_data_rv, filter = teal_slices()) {
  stopifnot(is.reactive(teal_data_rv))
  moduleServer(id, function(input, output, session) {
    logger::log_trace("srv_teal initializing the module.")

    output$identifier <- renderText(
      paste0("Pid:", Sys.getpid(), " Token:", substr(session$token, 25, 32))
    )

    teal.widgets::verbatim_popup_srv(
      "sessionInfo",
      verbatim_content = utils::capture.output(utils::sessionInfo()),
      title = "SessionInfo"
    )

    output$lockFile <- teal_lockfile_downloadhandler()

    # `JavaScript` code
    run_js_files(files = "init.js")

    # set timezone in shiny app
    # timezone is set in the early beginning so it will be available also
    # for `DDL` and all shiny modules
    get_client_timezone(session$ns)
    observeEvent(
      eventExpr = input$timezone,
      once = TRUE,
      handlerExpr = {
        session$userData$timezone <- input$timezone
        logger::log_trace("srv_teal@1 Timezone set to client's timezone: { input$timezone }.")
      }
    )

    reporter <- teal.reporter::Reporter$new()$set_id(attr(filter, "app_id"))
    if (is_arg_used(modules, "reporter") && length(extract_module(modules, "teal_module_previewer")) == 0) {
      modules <- append_module(
        modules,
        reporter_previewer_module(server_args = list(previewer_buttons = c("download", "reset")))
      )
    }


    datasets_reactive <- eventReactive(teal_data_rv(), {
      progress_data <- Progress$new(
        max = length(unlist(module_labels(modules)))
      )
      on.exit(progress_data$close())
      progress_data$set(message = "Preparing data filtering", detail = "0%")
      # Restore filter from bookmarked state, if applicable.
      filter_restored <- restoreValue("filter_state_on_bookmark", filter)
      if (!is.teal_slices(filter_restored)) {
        filter_restored <- as.teal_slices(filter_restored)
      }
      # Create list of `FilteredData` objects that reflects structure of `modules`.
      modules_datasets(teal_data_rv(), modules, filter_restored, teal_data_to_filtered_data(teal_data_rv()), progress_data) # nolint: line_length.
    })


    # Replace splash / welcome screen once data is loaded ----
    # ignoreNULL to not trigger at the beginning when data is NULL
    # just handle it once because data obtained through delayed loading should
    # usually not change afterwards
    # if restored from bookmarked state, `filter` is ignored

    observeEvent(datasets_reactive(), once = TRUE, {
      logger::log_trace("srv_teal@5 setting main ui after data was pulled")
      datasets <- datasets_reactive()

      progress_modules <- Progress$new(
        max = length(unlist(module_labels(modules)))
      )
      on.exit(progress_modules$close())
      progress_modules$set(value = 0, message = "Preparing modules", detail = "0%")

      # main_ui_container contains splash screen first and we remove it and replace it by the real UI
      removeUI(sprintf("#%s > div:nth-child(1)", session$ns("main_ui_container")))
      insertUI(
        selector = paste0("#", session$ns("main_ui_container")),
        where = "beforeEnd",
        # we put it into a div, so it can easily be removed as a whole, also when it is a tagList (and not
        # just the first item of the tagList)
        ui = tags$div(ui_tabs_with_filters(
          session$ns("main_ui"),
          modules = modules,
          datasets = datasets,
          filter = filter,
          progress = progress_modules
        )),
        # needed so that the UI inputs are available and can be immediately updated, otherwise, updating may not
        # have any effect as they are ignored when not present
        immediate = TRUE
      )

      progress_modules$set(message = "Finalizing")

      # must make sure that this is only executed once as modules assume their observers are only
      # registered once (calling server functions twice would trigger observers twice each time)
      srv_tabs_with_filters(
        id = "main_ui",
        datasets = datasets,
        modules = modules,
        reporter = reporter,
        filter = filter
      )
    })
  })
}
