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
   <link rel="stylesheet" href="claw-style.css">
</head>
<body>
   <div class="shell">
      <header>
         <div class="brand">
            <img class="mark" src="LSP-Claw-Icon.png" alt="LSP-Claw icon" width="74" height="74">
            <div>
               <h1>LSP-Claw</h1>
               <p class="subtitle">
                  MCP setup for BAS, Mako Server, and Xedge<br>
                  <a class="doc-link" href="https://github.com/RealTimeLogic/LSP-Claw/blob/main/README.md#first-useful-prompt" target="_blank" rel="noopener">LSP-Claw Tutorial</a>
               </p>
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
