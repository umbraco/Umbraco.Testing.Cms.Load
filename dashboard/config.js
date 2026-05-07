// Dashboard runtime config. The deploy script (scripts/deploy-dashboard.ps1)
// rewrites this file at deploy time with a fresh SAS token + the actual
// storage account / container names. Default placeholders here are used only
// for local-dev preview against a hand-edited config.
//
// SAS scope: read + list, container-only. Can leak via screenshot but the
// dashboard is gated behind Entra-ID auth via Static Web Apps, so only
// authenticated tenant users can see it. Regenerate via redeploy when the
// SAS expires.
window.DASHBOARD_CONFIG = {
    storageAccount: "REPLACE_AT_DEPLOY",
    container:      "REPLACE_AT_DEPLOY",
    sas:            "REPLACE_AT_DEPLOY"
};
