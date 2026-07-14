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
local githubTokenInput = githubToken
local action = request:data("action")
local message, errorMessage, githubTokenError

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
   githubTokenInput = newGithubToken
   local tokenValid,validation
   if newGithubToken then tokenValid,validation=app.validateGitHubToken(newGithubToken) end
   if newGithubToken and not tokenValid then
      githubTokenError=validation or "GitHub rejected this token."
      errorMessage="Token settings were not saved; the previous settings remain active."
   else
      local saved,saveErr=app.saveTokens(newGithubToken,newAuthToken)
      if not saved then
         errorMessage="Token settings could not be saved: "..tostring(saveErr or "unknown error")
      else
         githubToken, authToken = app.getSetTokens()
         githubTokenInput = githubToken
         authRequired = authToken ~= nil and authToken ~= ""
         authorized = not authRequired or user == adminUser
         local login=validation and validation.login
         message = login and ("Token settings saved. GitHub token validated for "..login..".") or "Token settings saved."
      end
   end
end


local labs, labsError
if authorized then labs, labsError = app.listLabs() end

local githubSet = githubToken ~= nil and githubToken ~= ""
local authSet = authToken ~= nil and authToken ~= ""
?>
<!doctype html>
<html lang="en">
<head>
   <meta charset="utf-8">
   <meta name="viewport" content="width=device-width, initial-scale=1">
   <title>LSP-Claw Configuration</title>
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
                  <a class="doc-link" href="https://github.com/RealTimeLogic/LSP-Claw#first-useful-prompt" target="_blank" rel="noopener">LSP-Claw prompt tutorial</a>
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
                        <input id="githubToken" name="githubToken" type="password" autocomplete="off" value="<?lsp= html(githubTokenInput) ?>"<?lsp= githubTokenError and ' aria-invalid="true" aria-describedby="githubTokenError"' or "" ?>>
                        <p class="field-note">Leave blank to store no GitHub token.</p>
                        <?lsp if githubTokenError then ?>
                        <p class="field-error" id="githubTokenError" role="alert"><?lsp= html(githubTokenError) ?></p>
                        <?lsp end ?>
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

         <section class="panel" id="lab-manager">
            <div class="panel-head">
               <h2>Lab archives</h2>
            </div>
            <div class="panel-body">
               <p class="field-note">Download or upload a complete lab as a ZIP file. LSP-Claw exports without compression and accepts stored or compressed ZIPs.</p>
               <?lsp if labsError then ?>
               <p class="error"><?lsp= html(labsError) ?></p>
               <?lsp elseif not labs or #labs == 0 then ?>
               <p>No labs exist yet. Upload an archive below and choose <strong>Create new lab</strong>.</p>
               <?lsp else ?>
               <div class="lab-list">
                  <?lsp for _, lab in ipairs(labs) do ?>
                  <div class="lab-row">
                     <div>
                        <strong><?lsp= html(lab.name) ?></strong>
                        <span class="field-note">/<?lsp= html(lab.basePath) ?><?lsp= lab.basePath ~= "" and "/" or "" ?> &middot; <span class="lab-state"><?lsp= lab.running and "running" or "stopped" ?></span></span>
                        <span class="lab-operation-status field-note" role="status" aria-live="polite"></span>
                     </div>
                     <div class="lab-actions">
                        <button class="secondary toggle-lab<?lsp= lab.running and " stop" or "" ?>" type="button" data-lab-name="<?lsp= html(lab.name) ?>" data-running="<?lsp= lab.running and "true" or "false" ?>"><?lsp= lab.running and "Stop lab" or "Start lab" ?></button>
                        <button class="secondary download-lab" type="button" data-lab-name="<?lsp= html(lab.name) ?>">Download ZIP</button>
                     </div>
                  </div>
                  <?lsp end ?>
               </div>
               <?lsp end ?>

               <form id="labUploadForm" class="archive-upload">
                  <div class="grid">
                     <div>
                        <label for="labArchive">Lab ZIP</label>
                        <input id="labArchive" type="file" accept=".zip,application/zip" required>
                     </div>
                     <div>
                        <label for="destinationLabName">Destination lab name</label>
                        <input id="destinationLabName" type="text" maxlength="64" pattern="[A-Za-z0-9][A-Za-z0-9_-]*" required>
                     </div>
                     <div>
                        <label for="conflictAction">Import action</label>
                        <select id="conflictAction">
                           <option value="createNew">Create new lab</option>
                           <option value="replace">Replace stopped lab</option>
                        </select>
                     </div>
                     <div id="replaceConfirmation" hidden>
                        <label><input id="confirmedReplace" type="checkbox"> I confirm complete replacement of the destination lab</label>
                     </div>
                  </div>
                  <div class="actions">
                     <button type="submit">Upload and import ZIP</button>
                  </div>
                  <p id="archiveStatus" class="field-note" role="status"></p>
               </form>
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

      const uploadForm = document.getElementById("labUploadForm");
      const conflictAction = document.getElementById("conflictAction");
      const replaceConfirmation = document.getElementById("replaceConfirmation");
      const confirmedReplace = document.getElementById("confirmedReplace");
      const archiveStatus = document.getElementById("archiveStatus");
      if (conflictAction) {
         conflictAction.addEventListener("change", () => {
            const replacing = conflictAction.value === "replace";
            replaceConfirmation.hidden = !replacing;
            confirmedReplace.required = replacing;
            if (!replacing) confirmedReplace.checked = false;
         });
      }
      if (uploadForm) {
         uploadForm.addEventListener("submit", async (event) => {
            event.preventDefault();
            const file = document.getElementById("labArchive").files[0];
            const labName = document.getElementById("destinationLabName").value;
            archiveStatus.textContent = "Preparing secure upload...";
            try {
               const params = new URLSearchParams({
                  action: "prepareImport",
                  labName,
                  conflictAction: conflictAction.value,
                  confirmed: String(confirmedReplace.checked)
               });
               const preparedResponse = await fetch("lab-api.lsp", {
                  method: "POST",
                  credentials: "same-origin",
                  headers: {"Content-Type": "application/x-www-form-urlencoded"},
                  body: params
               });
               const prepared = await preparedResponse.json();
               if (!preparedResponse.ok || !prepared.ok) throw new Error(prepared.error || "Cannot prepare import");
               archiveStatus.textContent = "Uploading and validating archive...";
               const uploadResponse = await fetch(prepared.result.uploadPath, {
                  method: "POST",
                  credentials: "same-origin",
                  headers: {"Content-Type": "application/zip"},
                  body: file
               });
               const imported = await uploadResponse.json();
               if (!uploadResponse.ok || !imported.ok) throw new Error(imported.error || "Import failed");
               archiveStatus.textContent = `Imported ${imported.result.fileCount} files into ${imported.result.labName}. Reloading...`;
               window.setTimeout(() => window.location.reload(), 800);
            } catch (error) {
               archiveStatus.textContent = error.message;
            }
         });
      }
      document.querySelectorAll(".toggle-lab").forEach((button) => {
         button.addEventListener("click", async () => {
            const row = button.closest(".lab-row");
            const state = row.querySelector(".lab-state");
            const operationStatus = row.querySelector(".lab-operation-status");
            const shouldRun = button.dataset.running !== "true";
            button.disabled = true;
            operationStatus.classList.remove("field-error");
            operationStatus.textContent = shouldRun ? "Starting lab..." : "Stopping lab...";
            try {
               const params = new URLSearchParams({
                  action: "setRunning",
                  labName: button.dataset.labName,
                  running: String(shouldRun)
               });
               const response = await fetch("lab-api.lsp", {
                  method: "POST",
                  credentials: "same-origin",
                  headers: {"Content-Type": "application/x-www-form-urlencoded"},
                  body: params
               });
               const changed = await response.json();
               if (!response.ok || !changed.ok) throw new Error(changed.error || "Cannot change lab state");
               const running = changed.result.running === true;
               button.dataset.running = String(running);
               button.textContent = running ? "Stop lab" : "Start lab";
               button.classList.toggle("stop", running);
               state.textContent = running ? "running" : "stopped";
               operationStatus.textContent = running ? "Lab started." : "Lab stopped.";
            } catch (error) {
               operationStatus.classList.add("field-error");
               operationStatus.textContent = error.message;
            } finally {
               button.disabled = false;
            }
         });
      });
      document.querySelectorAll(".download-lab").forEach((button) => {
         button.addEventListener("click", async () => {
            button.disabled = true;
            try {
               const params = new URLSearchParams({action: "prepareExport", labName: button.dataset.labName});
               const response = await fetch("lab-api.lsp", {
                  method: "POST",
                  credentials: "same-origin",
                  headers: {"Content-Type": "application/x-www-form-urlencoded"},
                  body: params
               });
               const prepared = await response.json();
               if (!response.ok || !prepared.ok) throw new Error(prepared.error || "Cannot prepare export");
               window.location.assign(prepared.result.downloadPath);
            } catch (error) {
               archiveStatus.textContent = error.message;
               button.disabled = false;
            }
         });
      });
   </script>
</body>
</html>
