# agent-shell-janitor

List and clean up idle agent-shell buffers.

## Features

- **List** agent shells in ibuffer, showing how long each has been idle and
  which eyebrowse workspaces show it.
- **Mark** orphaned shells (idle, and shown by no window or workspace) for
  deletion in that list.
- **Kill** orphans that have been idle for a day, e.g. daily from
  `midnight-hook`.

Idle time comes from agent-shell's last-activity time rather than
`buffer-display-time`, which eyebrowse resets for every buffer in a workspace
on each switch.

## Usage

- `agent-shell-janitor-list`: list shells, with orphans marked. `x` kills them.
- `agent-shell-janitor-kill-stale`: kill orphans idle for longer than
  `agent-shell-janitor-stale-age` (one day by default).

The list's columns are set by `agent-shell-janitor-ibuffer-format`.

## Installation

Not on MELPA, but you can do:

```elisp
(use-package agent-shell-janitor
  :load-path "~/.emacs.d/packages/agent-shell-janitor"
  :commands (agent-shell-janitor-list agent-shell-janitor-kill-stale)
  :init
  ;; Appended, so an error won't stop `clean-buffer-list' from running.
  (add-hook 'midnight-hook #'agent-shell-janitor-kill-stale t))
```

## Compatibility

Reads agent-shell's private `:last-activity-time` state, and eyebrowse's
private window-config helpers.  Upstream changes may require updates here.

## Testing

No dependencies needed; agent-shell and eyebrowse are stubbed:

```sh
emacs --batch -Q -l tests/run-tests.el
```

## License

GPL-3.0-or-later.
