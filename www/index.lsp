<?lsp
response:setheader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
response:setheader("Pragma", "no-cache")

local function html(value)
   value = tostring(value or "")
   value = value:gsub("&", "&amp;")
   value = value:gsub("<", "&lt;")
   value = value:gsub(">", "&gt;")
   value = value:gsub('"', "&quot;")
   return value:gsub("'", "&#39;")
end

local function trimToNil(value)
   if type(value) ~= "string" then return nil end
   value = value:gsub("^%s+", ""):gsub("%s+$", "")
   if value == "" then return nil end
   return value
end

local adminUser = "lsp-claw-admin"
local githubToken, authToken = app.getSetTokens()
local action = request:data("action")
local message, errorMessage

if action == "logout" then
   request:logout()
end

local user = request:user()
local authRequired = authToken ~= nil and authToken ~= ""
local authorized = not authRequired or user == adminUser

if action == "login" and authRequired then
   local loginToken = request:data("loginToken")
   if loginToken == authToken then
      request:login(adminUser, 1, true)
      user = request:user()
      authorized = true
      message = "Signed in."
   else
      errorMessage = "Invalid authentication token."
   end
end

if action == "save" and authorized then
   local newGithubToken = trimToNil(request:data("githubToken"))
   local newAuthToken = trimToNil(request:data("authToken"))
   app.getSetTokens(newGithubToken, newAuthToken)
   githubToken, authToken = app.getSetTokens()
   authRequired = authToken ~= nil and authToken ~= ""
   authorized = not authRequired or user == adminUser
   message = "Token settings saved."
end

local githubSet = githubToken ~= nil and githubToken ~= ""
local authSet = authToken ~= nil and authToken ~= ""
?>
<!doctype html>
<html lang="en">
<head>
   <meta charset="utf-8">
   <meta name="viewport" content="width=device-width, initial-scale=1">
   <title>LSP-Claw Token Setup</title>
   <link rel="icon" type="image/png" href="LSP-Claw-Icon.png">
   <style>
      :root {
         color-scheme: light;
         --bg: #eef2f7;
         --panel: #ffffff;
         --text: #172033;
         --muted: #607087;
         --line: #d8e0ea;
         --accent: #0f766e;
         --accent-strong: #115e59;
         --warning: #b45309;
         --danger: #b42318;
         --ok: #047857;
         --shadow: 0 18px 48px rgba(23, 32, 51, .13);
      }
      * { box-sizing: border-box; }
      body {
         margin: 0;
         min-height: 100vh;
         font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         color: var(--text);
         background:
            radial-gradient(circle at top left, rgba(15, 118, 110, .16), transparent 34rem),
            linear-gradient(135deg, #f8fafc 0%, var(--bg) 100%);
      }
      .shell {
         width: min(920px, calc(100% - 32px));
         margin: 0 auto;
         padding: 42px 0;
      }
      header {
         display: flex;
         align-items: center;
         justify-content: space-between;
         gap: 20px;
         margin-bottom: 28px;
      }
      .brand {
         display: flex;
         align-items: center;
         gap: 16px;
      }
      .mark {
         width: 74px;
         height: 74px;
         border-radius: 8px;
         object-fit: contain;
      }
      h1 {
         margin: 0;
         font-size: clamp(2rem, 5vw, 3.8rem);
         line-height: 1;
         letter-spacing: 0;
      }
      .subtitle {
         margin: 8px 0 0;
         color: var(--muted);
         font-size: 1rem;
      }
      .status-row {
         display: flex;
         flex-wrap: wrap;
         gap: 10px;
      }
      .pill {
         display: inline-flex;
         align-items: center;
         min-height: 32px;
         padding: 6px 10px;
         border: 1px solid var(--line);
         border-radius: 8px;
         background: rgba(255, 255, 255, .72);
         color: var(--muted);
         font-size: .9rem;
      }
      .pill.ok { color: var(--ok); border-color: rgba(4, 120, 87, .25); }
      .pill.warn { color: var(--warning); border-color: rgba(180, 83, 9, .25); }
      main {
         display: grid;
         grid-template-columns: minmax(0, 1fr);
         gap: 18px;
      }
      .panel {
         background: rgba(255, 255, 255, .94);
         border: 1px solid rgba(216, 224, 234, .9);
         border-radius: 8px;
         box-shadow: var(--shadow);
         overflow: hidden;
      }
      .panel-head {
         padding: 22px 24px 0;
      }
      h2 {
         margin: 0;
         font-size: 1.35rem;
         letter-spacing: 0;
      }
      .panel-body {
         padding: 22px 24px 24px;
      }
      .grid {
         display: grid;
         grid-template-columns: repeat(2, minmax(0, 1fr));
         gap: 18px;
      }
      label {
         display: block;
         margin: 0 0 8px;
         color: #2c3a4d;
         font-weight: 700;
         font-size: .95rem;
      }
      input {
         width: 100%;
         min-height: 46px;
         border: 1px solid var(--line);
         border-radius: 8px;
         padding: 11px 12px;
         color: var(--text);
         background: #fbfdff;
         font: inherit;
      }
      input:focus {
         outline: 3px solid rgba(15, 118, 110, .18);
         border-color: var(--accent);
      }
      .field-note {
         margin: 8px 0 0;
         color: var(--muted);
         font-size: .88rem;
      }
      .actions {
         display: flex;
         align-items: center;
         justify-content: space-between;
         flex-wrap: wrap;
         gap: 12px;
         margin-top: 22px;
      }
      button {
         min-height: 44px;
         border: 0;
         border-radius: 8px;
         padding: 10px 16px;
         background: var(--accent);
         color: #ffffff;
         font: inherit;
         font-weight: 750;
         cursor: pointer;
      }
      button:hover { background: var(--accent-strong); }
      .secondary {
         border: 1px solid var(--line);
         background: #ffffff;
         color: var(--text);
      }
      .secondary:hover { background: #f3f6fa; }
      .message, .error {
         margin: 0 0 18px;
         padding: 12px 14px;
         border-radius: 8px;
         font-weight: 650;
      }
      .message {
         background: rgba(4, 120, 87, .1);
         color: var(--ok);
         border: 1px solid rgba(4, 120, 87, .18);
      }
      .error {
         background: rgba(180, 35, 24, .1);
         color: var(--danger);
         border: 1px solid rgba(180, 35, 24, .18);
      }
      .login-card {
         max-width: 520px;
      }
      .token-tools {
         display: flex;
         gap: 10px;
         margin-top: 10px;
      }
      @media (max-width: 720px) {
         .shell { width: min(100% - 24px, 920px); padding: 24px 0; }
         header { align-items: flex-start; flex-direction: column; }
         .grid { grid-template-columns: 1fr; }
         .panel-head, .panel-body { padding-left: 18px; padding-right: 18px; }
         .actions { align-items: stretch; flex-direction: column; }
         button { width: 100%; }
      }
   </style>
</head>
<body>
   <div class="shell">
      <header>
         <div class="brand">
            <img class="mark" src="LSP-Claw-Icon.png" alt="LSP-Claw icon" width="74" height="74">
            <div>
               <h1>LSP-Claw</h1>
               <p class="subtitle">MCP setup for BAS, Mako Server, and Xedge</p>
            </div>
         </div>
         <div class="status-row">
            <span class="pill<?lsp= githubSet and " ok" or " warn" ?>">GitHub token: <?lsp= githubSet and "set" or "not set" ?></span>
            <span class="pill<?lsp= authSet and " ok" or " warn" ?>">MCP auth token: <?lsp= authSet and "set" or "not set" ?></span>
         </div>
      </header>

      <main>
         <?lsp if message then ?>
         <p class="message"><?lsp= html(message) ?></p>
         <?lsp end ?>
         <?lsp if errorMessage then ?>
         <p class="error"><?lsp= html(errorMessage) ?></p>
         <?lsp end ?>

         <?lsp if not authorized then ?>
         <section class="panel login-card">
            <div class="panel-head">
               <h2>Sign in</h2>
            </div>
            <div class="panel-body">
               <form method="post" autocomplete="off">
                  <input type="hidden" name="action" value="login">
                  <label for="loginToken">Authentication token</label>
                  <input id="loginToken" name="loginToken" type="password" autocomplete="current-password" autofocus>
                  <div class="actions">
                     <button type="submit">Continue</button>
                  </div>
               </form>
            </div>
         </section>
         <?lsp else ?>
         <section class="panel">
            <div class="panel-head">
               <h2>Token settings</h2>
            </div>
            <div class="panel-body">
               <form method="post" autocomplete="off">
                  <input type="hidden" name="action" value="save">
                  <div class="grid">
                     <div>
                        <label for="githubToken">GitHub token</label>
                        <input id="githubToken" name="githubToken" type="password" autocomplete="off" value="<?lsp= html(githubToken) ?>">
                        <p class="field-note">Leave blank to store no GitHub token.</p>
                     </div>
                     <div>
                        <label for="authToken">MCP authentication token</label>
                        <input id="authToken" name="authToken" type="password" autocomplete="off" value="<?lsp= html(authToken) ?>">
                        <p class="field-note">Leave blank to disable bearer-token authentication.</p>
                     </div>
                  </div>
                  <div class="token-tools">
                     <button class="secondary" type="button" id="toggleVisibility">Show tokens</button>
                  </div>
                  <div class="actions">
                     <button type="submit">Save tokens</button>
                  </div>
               </form>
               <?lsp if authSet then ?>
               <form method="post" autocomplete="off" class="actions">
                  <input type="hidden" name="action" value="logout">
                  <button class="secondary" type="submit">Sign out</button>
               </form>
               <?lsp end ?>
            </div>
         </section>
         <?lsp end ?>
      </main>
   </div>
   <script>
      const toggle = document.getElementById("toggleVisibility");
      if (toggle) {
         toggle.addEventListener("click", () => {
            const fields = [document.getElementById("githubToken"), document.getElementById("authToken")];
            const showing = fields.some((field) => field && field.type === "text");
            fields.forEach((field) => {
               if (field) field.type = showing ? "password" : "text";
            });
            toggle.textContent = showing ? "Show tokens" : "Hide tokens";
         });
      }
   </script>
</body>
</html>
