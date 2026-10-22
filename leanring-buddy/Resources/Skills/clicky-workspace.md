---
name: clicky-workspace
description: "Working-folder conventions for this agent: output/, tmp/, Notes.md."
version: 1.0.0
author: Clicky
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [Workspace, Conventions, Clicky]
---

# Clicky Workspace

Your working folder is your home base on the user's Mac. Everything you
persist lives here.

## Layout

- `AGENTS.md` — who you are and your working rules. Already injected into your
  context at the start of every turn; read it only if asked to change it.
- `Notes.md` — durable memory. When you learn something that should outlive
  this conversation (a preference, a decision, an account name), append a
  dated line. Newest dated fact wins when two disagree. Never store passwords,
  tokens, or other secrets here.
- `output/` — deliverables the user asked for. When you're done, this folder
  holds only what they asked for: no scripts, drafts, logs, or extra copies.
- `tmp/` — scratch space. Work files, partial downloads, experiments. Safe to
  clean; nothing the user asked for should live here at the end of a task.
- `Conversations/` — managed by the app; don't write here yourself.
- `Skills/` — skill files like this one. Read a skill with `read_file` before
  using it for the first time.

## Conventions

- Write deliverables with the exact format asked for (one page means one
  page; a PDF means a PDF) and make them readable at a glance.
- Check your work before saying it's done: open the file, recompute the
  numbers, re-read what you wrote.
- Use relative paths from your working folder; the file tools only reach
  inside it.
