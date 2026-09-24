# Omarchy Snowball Plugin

Omarchy **bar widget** for the [Snowball](https://github.com/tylergbrown/snowball) auto trader.

Shows live Coinbase equity, day PnL, a 7-day portfolio chart, per-book cards, and a double-confirm restart of the `snowball` Docker container. Money data is read over SSH into the trader host; health comes from the bot’s HTTP `/health` endpoint.

- Plugin id: `tb.snowball` (Omarchy install folder name)
- Repo: `omarchy-snowball-plugin`

## Install

```bash
omarchy plugin add https://github.com/tylergbrown/omarchy-snowball-plugin.git --enable --yes
```

If the chip does not appear:

```bash
omarchy-restart-shell
```

Update later:

```bash
omarchy plugin update tb.snowball --yes
omarchy-restart-shell
```

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `url` | `http://192.168.1.24:8080` | Snowball dashboard origin (Brown-02) |
| `pollSec` | `10` | Health poll interval |
| `snapshotSec` | `120` | Coinbase/detail refresh (`0` disables) |
| `staleTickSec` | `300` | Warn when last tick is older than this |
| `showPnl` | `true` | Show day PnL on the bar chip |
| `sshUser` | `tylerbrown` | SSH user for Coinbase read + restart |
| `container` | `snowball` | Docker container name to restart |

Defaults match the Brown-02 ZimaOS seat. On a new Omarchy install (Framework, etc.), point `url` at the host that runs Snowball and confirm SSH:

```bash
ssh -o BatchMode=yes tylerbrown@192.168.1.24 true
```

The plugin uses `~/.ssh/id_ed25519` (or your agent) from the Omarchy machine.

## Files

- `manifest.json` — Omarchy plugin metadata and settings schema
- `Widget.qml` — bar chip + popup UI
- `status.py` — health / Coinbase snapshot / docker restart helpers

## Notes

- Coinbase-only balances (no paper ledger books).
- Restart is double-confirm and restarts the Docker container over SSH.
- Requires Omarchy / Quickshell bar widgets (`BarWidget`, `PopupCard`, `qs.Commons`, `qs.Ui`).
