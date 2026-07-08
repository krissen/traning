# global.R — laddas en gång vid appstart
#
# Laddar paketet och binder den initiala session-snapshoten till
# globala namn för bakåtkompatibilitet. `server()` i app.R anropar
# `load_session_data()` igen per session så varje omladdad dashboard
# ser senaste cachen utan service-restart.

# Paketrot är två nivåer upp från app/tRanat/
# Shiny sätter working directory till app-katalogen när global.R körs,
# så "../.." ger korrekt paketrot oavsett hur appen startas.
pkg_root <- normalizePath(file.path(getwd(), "..", ".."))
suppressMessages(devtools::load_all(pkg_root, quiet = TRUE))

# --- Initial load vid process-start --------------------------------------
# load_session_data() returnerar nu en traning_data-bundle direkt (PR 8
# av S7-migreringen). Binder även upp de enskilda slotsen till globala
# namn så ev. legacy-konsumenter (utanför server()) ser samma data som
# tidigare. server() anropar load_session_data() på nytt per session
# och använder den färska bundlen direkt.
.initial_session_data <- load_session_data()
summaries       <- .initial_session_data@summaries
myruns          <- .initial_session_data@myruns
decoupling_data <- .initial_session_data@decoupling_data
health_daily    <- .initial_session_data@health_daily
rm(.initial_session_data)
