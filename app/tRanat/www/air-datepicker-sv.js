// air-datepicker-sv.js
//
// shinyWidgets::airDatepickerInput() is initialised with language = "en"
// everywhere in this app (see mod_date_preset.R, page_progress.R,
// page_race.R) because shinyWidgets' bundled air-datepicker v3 locale
// map has no "sv" entry, even though shinyWidgets' R-side match.arg()
// happily accepts "sv" — passing it crashes the JS binding's
// _handleLocale() (JSON.parse(JSON.stringify(undefined))) and takes the
// whole Shiny session down with it.
//
// This script supplies the missing Swedish locale ourselves, entirely
// client-side, by reaching into the AirDatepicker Shiny input binding's
// instance store and calling each instance's own `.update({locale})`
// method — the same API the binding uses internally, so no private
// internals of air-datepicker itself are touched.
//
// Everything here is defensively guarded: if Shiny, the binding, its
// store, or the `.update` method are missing or shaped differently
// (e.g. a future shinyWidgets upgrade), the script silently no-ops and
// the calendar simply stays in English. No console errors, ever.
(function () {
  "use strict";

  var SV = {
    days: ["söndag", "måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag"],
    daysShort: ["sön", "mån", "tis", "ons", "tors", "fre", "lör"],
    daysMin: ["sö", "må", "ti", "on", "to", "fr", "lö"],
    months: ["januari", "februari", "mars", "april", "maj", "juni", "juli",
             "augusti", "september", "oktober", "november", "december"],
    monthsShort: ["jan", "feb", "mar", "apr", "maj", "jun", "jul", "aug",
                  "sep", "okt", "nov", "dec"],
    today: "Idag",
    clear: "Rensa",
    dateFormat: "yyyy-MM-dd",
    timeFormat: "HH:mm",
    firstDay: 1
  };

  function findAirDatepickerBinding() {
    try {
      if (typeof Shiny === "undefined" || !Shiny.inputBindings ||
          !Shiny.inputBindings.bindings) {
        return null;
      }
      var entries = Shiny.inputBindings.bindings;
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (entry && entry.binding &&
            entry.binding.name === "shinyWidgets.AirDatepicker") {
          return entry.binding;
        }
      }
    } catch (e) {
      // fall through to null
    }
    return null;
  }

  function applySvToInstance(inst) {
    try {
      if (inst && typeof inst.update === "function") {
        inst.update({ locale: SV });
      }
    } catch (e) {
      // One bad instance must never block the others.
    }
  }

  function applySv(binding) {
    try {
      if (!binding || !binding.store) return;
      var ids = Object.keys(binding.store);
      for (var i = 0; i < ids.length; i++) {
        applySvToInstance(binding.store[ids[i]]);
      }
    } catch (e) {
      // Silently degrade — calendars stay English.
    }
  }

  function wrapUpdateStore(binding) {
    try {
      if (!binding || typeof binding.updateStore !== "function") return;
      if (binding.__svWrapped) return; // idempotent guard against double-wrap
      var original = binding.updateStore;
      binding.updateStore = function (el, instance) {
        var result = original.apply(this, arguments);
        try {
          applySvToInstance(instance);
        } catch (e) {
          // no-op
        }
        return result;
      };
      binding.__svWrapped = true;
    } catch (e) {
      // Silently degrade.
    }
  }

  function init() {
    var binding = findAirDatepickerBinding();
    if (!binding) return;
    wrapUpdateStore(binding);
    applySv(binding);
  }

  try {
    if (typeof $ !== "undefined") {
      $(document).on("shiny:connected", function () {
        init();
        // Backstop: some instances may be stored a beat after connect.
        setTimeout(init, 300);
      });
    }
  } catch (e) {
    // Silently degrade — no Swedish locale swap, no error surfaced.
  }
})();
