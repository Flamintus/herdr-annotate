# Trying the review loop in an isolated Herdr

`scripts/try-isolated.sh` runs this checkout's Full plugin in a Herdr instance of its own, so a
trial never touches the Herdr you work in: not its server, plugin registry, config or plugin
state, nor your Plannotator data.

## What is isolated, and how

Herdr 0.9.5 resolves everything from its config directory, `$XDG_CONFIG_HOME/herdr`, else
`~/.config/herdr`: `config.toml`, the plugin registry `plugins.json` and managed plugins, the API
and client sockets, session state and logs. Plugin state lives under `$XDG_STATE_HOME/herdr`,
else `~/.local/state/herdr`. `HERDR_SOCKET_PATH`, `HERDR_SESSION` and `HERDR_CONFIG_PATH` point a
command elsewhere. A named session has its own sockets but shares the registry and the config, so
it does not isolate a plugin.

Sources, at herdr `v0.9.5`: `src/config/io.rs` (`config_dir`, `state_dir`, `config_path`),
`src/session.rs` (`data_dir_for`, `api_socket_path_for`), `src/persist/plugin_registry.rs`
(`registry_path`), `src/plugin_paths.rs`, `src/cli/plugin.rs` (`plugin_link` writes the registry
itself when no server answers); the documentation's `socket-api.mdx` (Socket paths) and
`plugins.mdx` (Install and link).

The script runs every Herdr command of the trial with `XDG_CONFIG_HOME` and `XDG_STATE_HOME`
inside `TRIAL_DIR`, every `HERDR_*` and `PLANNOTATOR_*` variable removed, and
`PLANNOTATOR_DATA_DIR` inside `TRIAL_DIR` too, so plannotator-tui's config, its feedback archive
and the review journals it reads and writes are the trial's. The same commands run with
plannotator-tui's review loop on (`PLANNOTATOR_TUI_REVIEW_LOOP=1`) and with `TRIAL_DIR/bin`, where
`prepare` links the Plannotator build it is given, first on the `PATH`, so an agent started in the
trial answers through that build too. Before it links anything it checks
that the trial's config and state homes are not yours and that `herdr --help`, in that
environment, names the trial's `config.toml`. Linking writes the trial's registry directly; no
server runs until `start`. The trial's Herdr config turns off onboarding, whose integration setup
would write the agents' own settings, and the update check, whose `herdr update` would replace
the Herdr binary your everyday instance runs too.

`HOME` is kept, so Claude Code keeps its login, settings and transcripts. Programs that read
`XDG_CONFIG_HOME` (gh, mise, ...) do not find their usual config in the trial's panes.

## Steps

1. Build plannotator-tui with the review loop: `cargo build --release` in a checkout of
   `Flamintus/plannotator-tui` on `feat/inbox`. Build a Plannotator whose `plannotator threads
   --help` lists the client's actions (`view`, `comment`, `send`, ...): no release has them yet.

2. Prepare, from anywhere, Herdr included:

   ```sh
   PLANNOTATOR_TUI_BIN=<plannotator-tui>/target/release/plannotator-tui \
   PLANNOTATOR_BIN=<plannotator build> \
     bash scripts/try-isolated.sh prepare
   ```

   This stages `bin/herdr-annotate.exe` (the pinned release, unless it is there already) and
   `bin/plannotator-tui.exe` (that build) in this checkout, links the Plannotator build as
   `TRIAL_DIR/bin/plannotator`, writes the trial's Herdr keys when they are absent, and links this
   checkout into the trial's registry. It writes no plannotator-tui config: the review loop is
   turned on by the environment. A Herdr install from GitHub keeps its own `bin/` and does not
   see these binaries; a link of this same checkout in your everyday Herdr would.

3. From a terminal outside Herdr: `bash scripts/try-isolated.sh start`. This attaches to the
   trial instance and starts its server.

4. In the trial, open a pane and start `claude` there. A session started inside the instance
   reports its id through the Herdr integration you already have. Install no integration from
   the trial, by `herdr integration install` or a setup screen: that writes Claude Code's own
   settings, which both instances share.

5. `prefix+shift+o` (`annotate.last`) opens the picker, then the reply. Expected: comments are
   kept in the session's review journal as they are made; `E` sends them all, ending the round,
   and pastes into the agent's pane the text the journal composed, each comment under its id
   with how to answer through `plannotator reply`; the pane stays open; the agent's answers come
   into the boxes under each passage, marked new; `C`, `V`, `s` and `z` reply, resolve or open
   again, send a draft now and fold; a passage selected in a box's words takes a sub-thread; a
   resolved thread folds to a line starting with `▸`, where `j`/`k` stop and `l` or `Enter` draw
   it open to read (`▾` at its head, `h` there folds it again); a new `annotate.last` on the same
   session brings the comments and the answers back. The journal can be read from the trial too:

   ```sh
   bash scripts/try-isolated.sh run -- plannotator threads
   ```

   Without a Plannotator build that has the review journal, the footer says why, and `E` sends
   the review to the agent's pane once, as with the loop off.

6. Stop, remove the directory, and drop the build staged in `bin/`, which carries the pinned
   version's stamp and would otherwise stay there instead of the pinned release:

   ```sh
   bash scripts/try-isolated.sh stop
   rm -rf "${TRIAL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-annotate-trial}"
   rm -f bin/plannotator-tui.exe bin/plannotator-tui.version
   ```

`TRIAL_DIR` defaults to `${XDG_CACHE_HOME:-$HOME/.cache}/herdr-annotate-trial`, and a relative
one is made absolute. It has to be short enough for a Unix socket path: at most 103 bytes for
`<TRIAL_DIR>/config/herdr/herdr-client.sock` (macOS; Linux allows 107); the script refuses a
longer one.
