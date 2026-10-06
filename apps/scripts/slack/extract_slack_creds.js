/*
 * extract_slack_creds.js
 *
 * Run this in your browser's DevTools console while logged into Slack
 * (on app.slack.com or your-workspace.slack.com). It downloads a
 * `slack_c.json` file containing the two values slack_cli.py needs:
 *   - SLACK_TOKEN  : your xoxc- user token (read from localStorage)
 *   - SLACK_COOKIE : your `d` cookie value, xoxd- (you paste this)
 *
 * Then load it into the Keychain and delete it:
 *   python3 slack_cli.py import ~/Downloads/slack_c.json --delete-source
 *
 * Why the paste step: the `d` cookie is HttpOnly, so page JavaScript
 * is not allowed to read it. Everything else is automatic.
 *
 * How to run:
 *   1. Open Slack in the browser and make sure the workspace has loaded.
 *   2. Open DevTools (F12 or Cmd/Ctrl+Shift+I) -> Console tab.
 *   3. If Chrome shows a "Don't paste code" warning, type: allow pasting
 *   4. Paste this whole file and press Enter.
 *   5. When prompted, paste the `d` cookie value (see note below).
 *
 * Where to get the `d` cookie:
 *   DevTools -> Application tab -> Storage -> Cookies ->
 *   pick your Slack domain -> find the row named `d` -> copy its Value
 *   (it starts with xoxd-). Paste that when the script asks.
 *
 * The cookie is kept exactly as the browser stores it (URL-encoded, with
 * %2F, %2B, %3D). slack_cli.py sends it the same way, so do not decode it.
 */

(() => {
  // --- 1. token (xoxc-) from localStorage ------------------------------
  let token = null;
  let meta = {};
  try {
    const cfg = JSON.parse(localStorage.getItem("localConfig_v2") || "{}");
    const teams = cfg.teams || {};
    const ids = Object.keys(teams);
    if (ids.length === 0) throw new Error("no workspaces found in localConfig_v2");

    // default to the last active workspace, else the first one
    let pick =
      cfg.lastActiveTeamId && teams[cfg.lastActiveTeamId]
        ? cfg.lastActiveTeamId
        : ids[0];

    // if signed into several workspaces, let the user choose
    if (ids.length > 1) {
      const menu = ids
        .map((id, i) => `${i}: ${teams[id].name || teams[id].url || id}`)
        .join("\n");
      const ans = prompt(
        `You're signed into several workspaces.\nEnter the number to export:\n\n${menu}`,
        String(ids.indexOf(pick))
      );
      const idx = Number(ans);
      if (ans !== null && ids[idx] && teams[ids[idx]]) pick = ids[idx];
    }

    const t = teams[pick];
    token = t.token;
    meta = { team: t.name, url: t.url, user_id: t.user_id };
  } catch (e) {
    alert("Could not read the token from localStorage: " + e.message);
    return;
  }

  if (!token || !token.startsWith("xoxc-")) {
    alert(
      "No xoxc- token found. Make sure you're fully logged into Slack in this tab, then retry."
    );
    return;
  }

  // --- 2. cookie (xoxd-) -----------------------------------------------
  // HttpOnly, so document.cookie almost never has it; try anyway, then ask.
  // Keep the raw (URL-encoded) value: that is what the browser sends.
  let cookie = "";
  const m = document.cookie.match(/(?:^|;\s*)d=([^;]+)/);
  if (m) cookie = m[1];

  if (!cookie) {
    cookie =
      prompt(
        "Paste your `d` cookie value (it starts with xoxd-).\n\n" +
          "Find it in: DevTools -> Application -> Cookies -> your Slack domain " +
          "-> row `d` -> copy the Value."
      ) || "";
    cookie = cookie.trim().replace(/^d=/, "");
  }

  if (!cookie.startsWith("xoxd-")) {
    alert(
      "Heads up: that cookie value doesn't start with xoxd-. " +
        "The CLI will likely reject it — double-check you copied the `d` cookie."
    );
  }

  // --- 3. download slack_c.json ----------------------------------------
  const payload = {
    SLACK_TOKEN: token,
    SLACK_COOKIE: cookie,
    _meta: { ...meta, exported_at: new Date().toISOString() },
  };

  const blob = new Blob([JSON.stringify(payload, null, 2)], {
    type: "application/json",
  });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "slack_c.json";
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(a.href);

  console.log(
    "%cslack_c.json downloaded — keep it private; it's full access to your Slack account.",
    "color:green;font-weight:bold"
  );
})();
