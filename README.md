# VibeStack

**One file. Double-click. Build real apps with AI — no technical setup required.**

VibeStack is a single Windows PowerShell installer that turns a blank PC into a fully configured, AI-powered local app development platform. It's built for vibe coders, solo builders, and non-technical founders who want to build real software with AI tools like Dyad, Cursor, and Windsurf — without spending weeks fighting their computer first.

---

## Why This Exists

I built this working 60 hours a week running a cart business. I had ideas. I had AI tools that could write code. What I didn't have was time to fight infrastructure.

Every hour spent configuring a dev environment is an hour not spent building. VibeStack exists because the setup friction for local AI-assisted development on Windows is absurdly high, the tools that exist assume you already know what you're doing, and there's no reason a non-technical person should have to learn any of it just to build their idea.

If this helps one other person ship something — that's the win.

---

## What You Get

After running the installer, you have:

- A **dashboard** at `http://localhost:9999` that manages all your projects
- A **project generator** that scaffolds complete Next.js + Supabase apps in one click
- **One-click launchers** for every common operation — no terminal required
- A **local database** (Supabase/Postgres) per project, running in Docker
- **Automatic database migrations** — the AI writes schema files, your tables appear
- **AI prompt templates** built in — PLAN, BUILD, CONTINUE, FIX
- An **AI memory system** (Athena) that keeps context between coding sessions

---

## Requirements

- Windows 10 (build 19041+) or Windows 11
- Internet connection for first run (downloads Docker, Node.js, Supabase)
- ~10 GB free disk space
- That's it

The installer handles everything else.

---

## Install

1. Download `vibestack-installer15.ps1` from [Releases](../../releases)
2. Right-click it → **Run with PowerShell**

   Or open PowerShell and run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   & "$HOME\Downloads\vibestack-installer15.ps1"
   ```
3. Walk away. Come back in 20-30 minutes (first run downloads Docker images).
4. Double-click **VIBESTACK-DASHBOARD.cmd** on your Desktop to open the dashboard.

> **Note:** Run as a regular user, not Administrator. The installer will prompt for elevation when needed.

---

## The AI Workflow

Once installed, building an app looks like this:

1. Click **+ NEW PROJECT** on the dashboard, fill in what you want to build
2. Import the project folder into Dyad (or Cursor, Windsurf, VS Code)
3. Paste the **PLAN** prompt from the dashboard — AI writes a master plan, no code yet
4. Paste the **BUILD** prompt — AI starts building Phase 1
5. Paste **CONTINUE** for each next phase
6. Paste **FIX** when something breaks
7. Database tables appear automatically as the AI writes migrations
8. Your app runs live at `http://localhost:55010` the whole time

All four prompts are one-click copy from the dashboard. You never have to remember them.

---

## The Hard Problems It Solves

These are not obvious. They took months of iterative testing to find.

**pnpm layout conflict** — Dyad uses pnpm internally, which creates a symlinked `node_modules` that breaks Next.js CSS processing on Windows. VibeStack detects this on every app start and converts to a clean npm layout automatically.

**Database migrations never applying** — AI tools write migration files but have no mechanism to run them. VibeStack applies migrations on startup, watches for new files and applies them within 4 seconds, and provides a manual PUSH DB button as a fallback.

**Port conflicts** — Each project gets a 40-port block. Nothing ever steps on anything else.

**Admin vs user permissions** — The installer runs as admin, IDEs run as the current user. VibeStack grants the correct permissions after project creation so IDEs can write files without EPERM errors.

**Hyper-V port reservation** — On some machines, Hyper-V randomly claims port 9999. VibeStack detects and reserves it during installation before Hyper-V can grab it.

---

## Project Structure

Everything lives at `C:\VIBESTACK\`:

```
C:\VIBESTACK\
├── DASHBOARD\          Node.js/Express dashboard server
├── PROJECTS\           One folder per app
│   └── YOUR_APP\
│       ├── app\        Next.js App Router
│       ├── components\
│       ├── scripts\    Migration watcher, DB startup, env sync
│       ├── supabase\   Local DB config + migration files
│       ├── ATHENA_EXPORT\  AI memory (MASTERPLAN, PROGRESS, etc.)
│       ├── AI_RULES.md     Rules for AI agents working in this project
│       ├── PROMPT.md       Your app brief
│       └── START-APP.cmd   Double-click to run
├── TOOLS\
│   └── Athena-Public\  Shared AI memory across projects
├── VIBESTACK-DASHBOARD.cmd
├── VIBESTACK-WIPE.cmd
└── Create-New-VibeStack-App.cmd
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Installer | PowerShell 5.1 |
| Dashboard | Node.js + Express |
| App framework | Next.js 15 (React, App Router) |
| Styling | Tailwind CSS v3 |
| Database | Supabase local (Postgres via Docker) |
| Migrations | Supabase CLI + chokidar watcher |
| AI memory | Markdown flat files |
| Primary AI IDE | Dyad |
| Also works with | Cursor, Windsurf, VS Code + Cline/Roo |

---

## Known Issues / Limitations

- **Windows only** — this was built for Windows 10/11. Mac/Linux support would require a rewrite.
- **Watchpack warnings** — harmless errors about Windows system files (`pagefile.sys` etc.) appear in the terminal. They don't affect anything.
- **npm shamefully-hoist warning** — cosmetic warning from npm not understanding pnpm settings. Harmless.
- **First Dyad import is slow** — after importing a project into Dyad, the first `START APP` takes 1-2 minutes to convert the pnpm layout to npm. Every subsequent start is instant.

---

## Contributing

Pull requests welcome. The entire platform is one `.ps1` file with JavaScript embedded as PowerShell heredocs.

A few things to know before editing:

- All embedded JS lives inside `@'...'@` literal heredoc blocks — no PowerShell variable expansion inside
- Zero non-ASCII characters allowed — PowerShell 5.1 mangles UTF-8 in heredocs
- Regex inside heredocs needs double-escaping: `\\r?\\n` not `\r?\n`
- After any edit, validate with:
  ```bash
  grep -cE "@'$" vibestack-installer15.ps1   # should equal 13
  grep -c "^'@" vibestack-installer15.ps1    # should equal 13
  grep -Pc '[^\x00-\x7F]' vibestack-installer15.ps1  # should equal 0
  ```

**Things that would make great contributions:**
- Mac/Linux support (or a separate installer)
- VS Code / Cline walkthrough (analogous to the Dyad workflow)
- Additional AI IDE compatibility
- Better error recovery in the dashboard
- Tests

---

## License

MIT — do whatever you want with it. If you make it better, that's the whole point.

---

*Built by a solo builder who needed this to exist. If it helps you ship something, that's enough.*
