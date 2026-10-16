# Deliverable F -- Shiny demo dashboard.
#
# "Live" and "replay" are the same mechanism here: this app never talks to
# Twilio directly, it only reads logs/requests.jsonl and logs/audio/ (which
# api/plumber.R -- or R/seed_demo_logs.R for demo seeding -- populate). That
# means it degrades gracefully with no network by construction: pick any
# past request from the dropdown and every panel renders from local files.
#
# Run:
#   shiny::runApp("dashboard")

library(shiny)
library(ggplot2)
library(plotly)
library(tuneR)
library(seewave)
library(jsonlite)

# shiny::runApp() switches the working directory to dashboard/, but the
# request log stores audio paths relative to the repo root
# ("logs/audio/<hash>.wav"). Anchor everything to an absolute repo root
# (same approach as api/plumber.R) and resolve logged paths against it.
REPO_ROOT <- normalizePath(
  if (file.exists(file.path("R", "utils.R"))) "." else ".."
)
resolve_repo_path <- function(path) {
  if (is.na(path) || !nzchar(path)) return(NA_character_)
  if (grepl("^([A-Za-z]:)?[/\\\\]", path)) path else file.path(REPO_ROOT, path)
}
REQUEST_LOG_PATH    <- file.path(REPO_ROOT, "logs", "requests.jsonl")
CODEC_FIGURE_PATH   <- file.path(REPO_ROOT, "docs", "figures", "codec_before_after.png")
CODEC_FINDINGS_PATH <- file.path(REPO_ROOT, "docs", "codec_findings.md")

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

# ---- Log parsing -----------------------------------------------------------

#' Parse logs/requests.jsonl (one JSON object per line, written by
#' log_event() in R/utils.R) into a data frame, most recent first. Tolerant
#' of missing fields (different failure paths in api/plumber.R log different
#' keys) and of malformed lines (skipped, not fatal).
read_request_log <- function(path) {
  if (!file.exists(path)) return(data.frame())
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(trimws(lines))]
  if (length(lines) == 0) return(data.frame())

  rows <- lapply(lines, function(l) {
    entry <- tryCatch(jsonlite::fromJSON(l), error = function(e) NULL)
    if (is.null(entry)) return(NULL)
    data.frame(
      timestamp   = if (is.null(entry$timestamp)) NA_character_ else entry$timestamp,
      from        = if (is.null(entry$from)) NA_character_ else as.character(entry$from),
      outcome     = if (is.null(entry$outcome)) NA_character_ else entry$outcome,
      audio_hash  = if (is.null(entry$audio_hash)) NA_character_ else entry$audio_hash,
      audio_path  = if (is.null(entry$audio_path)) NA_character_ else entry$audio_path,
      duration_s  = suppressWarnings(as.numeric(if (is.null(entry$duration_s)) NA else entry$duration_s)),
      top_classes = if (is.null(entry$top_classes)) NA_character_ else entry$top_classes,
      confidences = if (is.null(entry$confidences)) NA_character_ else entry$confidences,
      stringsAsFactors = FALSE
    )
  })
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0) return(data.frame())
  out <- do.call(rbind, rows)
  out[order(out$timestamp, decreasing = TRUE), , drop = FALSE]
}

# ---- UI ----------------------------------------------------------------------

ui <- navbarPage(
  "SonicScout — Live Demo Dashboard",

  tabPanel("Live / Replay",
    sidebarLayout(
      sidebarPanel(
        selectInput("selected_request", "Request", choices = character(0)),
        helpText("Auto-refreshes when a new request is logged to logs/requests.jsonl. ",
                 "Pick any past request to replay it -- this works with no network ",
                 "connection, since every panel reads local log/audio files only."),
        tags$hr(),
        h5("Demo location (illustrative)"),
        helpText("SonicScout does not yet capture real GPS from WhatsApp messages ",
                 "-- this pin is a manually-set demo location, not derived from the ",
                 "request itself."),
        numericInput("demo_lat", "Latitude", value = -1.2921, step = 0.01),
        numericInput("demo_lon", "Longitude", value = 36.8219, step = 0.01)
      ),
      mainPanel(
        fluidRow(
          column(6, plotOutput("waveform_plot", height = "220px", width = "400px")),
          column(6, plotOutput("spectrogram_plot", height = "220px", width = "400px"))
        ),
        fluidRow(
          column(6, plotOutput("confidence_plot", height = "260px", width = "400px")),
          column(6, plotlyOutput("map_plot", height = "260px"))
        ),
        tags$hr(),
        verbatimTextOutput("request_details")
      )
    )
  ),

  tabPanel("Compression Analysis",
    fluidPage(
      h4("Before / after WhatsApp compression"),
      p("From the codec characterisation experiment (Deliverable A) — see ",
        code("docs/codec_findings.md"), " for the full write-up and measured numbers."),
      if (file.exists(CODEC_FIGURE_PATH)) {
        imageOutput("codec_figure", height = "auto")
      } else {
        p(em("Figure not yet generated -- run R/02_codec_experiment.R first."))
      },
      tags$hr(),
      uiOutput("codec_findings_md")
    )
  )
)

# ---- Server --------------------------------------------------------------------

server <- function(input, output, session) {
  log_reader <- reactiveFileReader(
    intervalMillis = 2000,
    session = session,
    filePath = REQUEST_LOG_PATH,
    readFunc = read_request_log
  )

  observe({
    df <- log_reader()
    if (nrow(df) == 0) return()
    labels <- sprintf("%s — %s (%s)", df$timestamp, df$outcome,
                       ifelse(is.na(df$top_classes), "", df$top_classes))
    choices <- stats::setNames(as.character(seq_len(nrow(df))), labels)

    current <- isolate(input$selected_request)
    # Auto-track the most recent request unless the presenter has manually
    # picked an older one to replay.
    selected <- if (is.null(current) || !(current %in% choices)) choices[[1]] else current
    updateSelectInput(session, "selected_request", choices = choices, selected = selected)
  })

  selected_row <- reactive({
    df <- log_reader()
    req(nrow(df) > 0, input$selected_request)
    idx <- as.integer(input$selected_request)
    df[idx, , drop = FALSE]
  })

  selected_wave <- reactive({
    row <- selected_row()
    audio_path <- resolve_repo_path(row$audio_path)
    req(!is.na(audio_path), file.exists(audio_path))
    tuneR::readWave(audio_path)
  })

  output$waveform_plot <- renderPlot({
    w <- tryCatch(selected_wave(), error = function(e) NULL)
    if (is.null(w)) {
      return(ggplot() + annotate("text", x = 0, y = 0, label = "No audio available for this request") + theme_void())
    }
    t <- seq_along(w@left) / w@samp.rate
    ggplot(data.frame(t = t, amp = w@left), aes(t, amp)) +
      geom_line(linewidth = 0.2) +
      labs(x = "Time (s)", y = "Amplitude", title = "Waveform") +
      theme_minimal()
  })

  output$spectrogram_plot <- renderPlot({
    w <- tryCatch(selected_wave(), error = function(e) NULL)
    if (is.null(w)) {
      return(ggplot() + annotate("text", x = 0, y = 0, label = "No audio available") + theme_void())
    }
    spec <- seewave::spectro(w, wl = 512, ovlp = 50, plot = FALSE)
    df <- data.frame(
      time = rep(spec$time, each = length(spec$freq)),
      freq = rep(spec$freq, times = length(spec$time)),
      amplitude = as.vector(spec$amp)
    )
    ggplot(df, aes(time, freq, fill = amplitude)) +
      geom_raster() +
      scale_fill_viridis_c() +
      labs(x = "Time (s)", y = "Frequency (kHz)", title = "Spectrogram", fill = "dB") +
      theme_minimal()
  })

  output$confidence_plot <- renderPlot({
    row <- selected_row()
    if (is.na(row$top_classes) || row$top_classes == "") {
      return(ggplot() + annotate("text", x = 0, y = 0, label = "No prediction for this request") + theme_void())
    }
    classes <- strsplit(row$top_classes, "\\|")[[1]]
    confidences <- as.numeric(strsplit(row$confidences, "\\|")[[1]])
    df <- data.frame(class = factor(classes, levels = rev(classes)), confidence = confidences)
    ggplot(df, aes(class, confidence)) +
      geom_col() +
      geom_text(aes(label = paste0(round(confidence * 100), "%")), hjust = -0.1) +
      coord_flip(ylim = c(0, 1)) +
      labs(x = NULL, y = "Confidence", title = "Top-3 candidates") +
      theme_minimal()
  })

  output$map_plot <- plotly::renderPlotly({
    plotly::plot_ly(
      type = "scattergeo", mode = "markers",
      lon = list(input$demo_lon), lat = list(input$demo_lat),
      marker = list(size = 14, color = "red")
    ) |>
      plotly::layout(
        geo = list(showland = TRUE, showcountries = TRUE,
                   projection = list(type = "natural earth")),
        title = "Report location (demo)"
      ) |>
      # scattergeo otherwise downloads its world outline from
      # https://cdn.plot.ly/world_110m.json at view time, which leaves a
      # blank map with no network. Serve the bundled copy from
      # dashboard/www/ instead so the demo survives a dead connection.
      plotly::config(topojsonURL = "./")
  })

  output$request_details <- renderPrint({
    row <- selected_row()
    cat("Timestamp:   ", row$timestamp %||% "-", "\n")
    cat("From:        ", row$from %||% "-", "\n")
    cat("Outcome:     ", row$outcome %||% "-", "\n")
    cat("Duration (s):", row$duration_s %||% NA, "\n")
    cat("Audio hash:  ", row$audio_hash %||% "-", "\n")
  })

  output$codec_figure <- renderImage({
    list(src = CODEC_FIGURE_PATH, contentType = "image/png", width = "100%")
  }, deleteFile = FALSE)

  output$codec_findings_md <- renderUI({
    if (!file.exists(CODEC_FINDINGS_PATH)) {
      return(p(em("docs/codec_findings.md not yet generated.")))
    }
    includeMarkdown(CODEC_FINDINGS_PATH)
  })
}

shinyApp(ui, server)
