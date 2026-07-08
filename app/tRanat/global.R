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
# load_session_data() returnerar en traning_data-bundle (PR 8 av
# S7-migreringen). Anropet här körs bara för att fail-fast:a på ett
# trasigt cache-läge vid appstart och värma ev. cold-path-beräkningar
# (t.ex. decoupling-cachen) innan första sessionen ansluter — inga
# konsumenter läser globala summaries/myruns/decoupling_data/
# health_daily längre (grep-verifierat), så resultatet binds inte upp.
# server() anropar load_session_data() på nytt per session och
# använder den färska bundlen direkt.
invisible(load_session_data())
