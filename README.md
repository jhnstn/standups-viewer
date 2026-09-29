# Standups viewer

A small native macOS app for reading daily standup reports: markdown files
named `YYYY-MM-DD.md` in one folder. It lists them grouped into two-week
periods, renders the selected one, and can generate or update today's report
by running a Claude Code skill headlessly.

It pairs with a `/standup` [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that writes those files;
any tool that writes `YYYY-MM-DD.md` files works for viewing.

## Features

- Sidebar of reports, newest first, grouped into two-week periods aligned to Mondays.
- Rendered markdown (GitHub-flavoured: task lists, tables, code), light and dark mode.
  Links open in your default browser, and task-list checkboxes can be ticked; the
  change is written straight back to the file.
- Optional YAML frontmatter (`window:`, `threads:`) is shown as a header line.
- **Generate today / Update today** (toolbar or ⌘G). With no report for today it runs
  `claude -p '/standup'`; once today's file exists it runs `claude -p '/standup update'`.
- Watches the folder, and notices a new day at midnight, on wake, and when the app
  comes forward, so the button follows the date without a restart.

## Build

Needs macOS 14+ and Xcode (for the SDK and `swiftc`). There is no Xcode project;
`build.sh` compiles `Sources/*.swift` into an app bundle.

```sh
./build.sh            # build/Standups.app
./build.sh --install  # also copies it to ~/Applications
```

## Configure

Both settings are optional.

```sh
# Where the reports live (default ~/Projects/standups)
defaults write com.jhnstn.standups StandupsDirectory "~/Documents/standups"

# Extra tools the headless claude run may use, e.g. MCP tools your skill calls
defaults write com.jhnstn.standups ExtraAllowedTools -array "mcp__myserver__search" "mcp__myserver__fetch"
```

The headless run uses `--permission-mode default` with an explicit allowlist:
Bash, Read, Write, Edit, Glob, Grep, Skill, ToolSearch, Agent, plus the extras above.
`claude` is resolved through your login shell, so it must be on the PATH your
`~/.zprofile` / `~/.zshrc` sets up.

## Credits

Markdown rendering uses [marked](https://github.com/markedjs/marked) (MIT), bundled in
`Resources/marked.min.js`.

## License

MIT
