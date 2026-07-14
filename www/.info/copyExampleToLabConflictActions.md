- Ask the user to choose a conflictAction.
- If the user chooses backupExisting, ask for an exact backupName unless the
  user already supplied one. Never invent or infer the name.
- Call copyExampleToLab with confirmed = true only after user confirmation.
