Build from an LSP-Claw example.

Selected example: %s
User goal: %s

1. Discover examples with listExamples or suggestExamples.
2. Inspect the selected example with inspectExample.
3. Plan the copy with planCopyExampleToLab.
4. Select the appRootPath returned by the plan. Ask the user when multiple variants are available.
5. Ask the user how to handle conflicts when the lab contains files.
6. Copy with copyExampleToLab, setting appRootPath and setting confirmed = true only after explicit user confirmation.
7. Modify lab files using readLabFile and writeLabFile.
8. Start the lab with startLab.
9. Report changed files, copied files, and runtime warnings.
