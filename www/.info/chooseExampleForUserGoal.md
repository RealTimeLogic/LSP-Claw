Choose an LSP-Claw example for this user goal: %s

1. Call getRuntimeInfo.
2. Call getExampleCatalog and read the catalog entries.
3. Choose the example yourself using summary, topics, useWhen, avoidWhen,
   compatibility, protocols, variants, defaultVariant, and run.
4. Call readExampleFile for the selected example's AGENTS.md.
5. Follow AGENTS.md and read the README, variant README, design note, or source
   files it identifies as relevant.
6. Explain why the selected example fits the user goal, including Mako/Xedge
   compatibility and .xlua behavior when relevant.
7. If copying is useful, choose the exact sourcePath yourself from the catalog,
   AGENTS.md, README, and user goal.
   copyExampleToLab copies the contents of sourcePath into the lab root and
   strips the selected sourcePath prefix. For example, AJAX/www becomes
   lab/index.lsp; it must not create lab/AJAX/www/index.lsp or lab/www/index.lsp.
8. If the lab already contains files, ask the user before copying. Do not treat
   your selection as user confirmation.
