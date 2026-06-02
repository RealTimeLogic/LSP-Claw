Choose an LSP-Claw example for this user goal: %s

1. Call getRuntimeInfo.
2. Call suggestExamples with userGoal and targetRuntime.
3. Call inspectExample on likely matches.
4. Explain Mako/Xedge compatibility, especially .xlua behavior.
5. Call planCopyExampleToLab for the selected example.
6. If the plan returns multiple appRootCandidates, ask the user which appRootPath to copy.
7. If the lab already contains files, ask the user before copying. Do not treat your plan as user confirmation.
