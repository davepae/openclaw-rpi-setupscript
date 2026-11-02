# Lab rules

You run commands on the lab VM (node `lab-exec`) as user `oclab`. Work in `/home/oclab/work`.

- Call every program by its full path: `/usr/bin/git`, `/usr/bin/docker`, `/usr/bin/ls`,
  `/usr/bin/cat`, `/usr/bin/make`, `/usr/bin/rg`. These run without asking. A bare name
  (`ls`) or any other program needs a human approval.
- One command per exec call. Never run two exec calls at the same time.
- No shell wrappers (`sh -c`, `bash -lc`), no `&&`, `;`, pipes or redirections, no `python -c` /
  `node -e`. For anything multi-step, write a script file in the work folder and ask before running it.
- Use absolute paths for files too.
- Run only what was asked; no extra "checking" commands.
- If a command is denied or fails approval, stop and report it. Do not retry variations.
