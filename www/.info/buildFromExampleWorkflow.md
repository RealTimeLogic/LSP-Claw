Build from an LSP-Claw example.

Selected example: %s
User goal: %s

1. Discover examples with getExampleCatalog. The AI agent must choose the
   example; LSP-Claw does not rank examples.
2. Read the selected example's AGENTS.md with readExampleFile.
3. Follow AGENTS.md and read the README, variant README, design note, or source
   files it identifies as relevant.
4. Select the exact sourcePath to copy. Use catalog run/variant context,
   AGENTS.md, README instructions, and the user goal. Ask the user when the
   variant or source path is ambiguous.
   copyExampleToLab copies the contents of sourcePath into the lab root and
   strips the selected sourcePath prefix. For example, AJAX/www becomes
   lab/index.lsp; it must not create lab/AJAX/www/index.lsp or lab/www/index.lsp.
5. Ask the user how to handle conflicts when the lab contains files.
6. Copy with copyExampleToLab, setting sourcePath and setting confirmed = true only after explicit user confirmation.
7. Modify lab files using readLabFile and writeLabFile.
8. Start the lab with startLab.
9. Report changed files, copied files, and runtime warnings.
