# BTClock for Omarchy

A status bar widget that shows live Bitcoin network data on a row of small
panels, one character each, in the style of the BTClock e-paper desk clock.

Inspired by **[btclock.store](https://btclock.store)**, where you can get the
real thing: a DIY multi-panel e-paper Bitcoin clock for your desk, with parts
and firmware. This widget is an independent tribute that borrows the device's
screens and formatting conventions — it is not affiliated with the project.
Firmware source lives at [git.btclock.dev](https://git.btclock.dev).

![preview](preview.png)

Four screens rotate in a single bar slot:

| Screen | Example | What it is |
| --- | --- | --- |
| Block height | `₿966251` | Current tip height |
| Fiat price | `$78 730` | Price of 1 BTC in the selected currency |
| Moscow time | `1 270/$` | Sats per unit of that currency (100,000,000 ÷ price) |
| Fee rates | `1/1/3` | Economy / half-hour / fastest, in sat/vB |

Strings shorter than the panel count are centred with blank panels, and a price
too wide to spell out falls back to a compact suffix (`¥12.1M`), which is what
the device does in its `suffixPrice` mode.

## Install

```bash
omarchy plugin add https://github.com/kravens/omarchy-btclock --enable
```

No accounts, no API keys, no external tools to install: it uses `bash`, `curl`,
`jq`, `setsid` and `timeout`, all of which Omarchy already ships.

## Controls

The mouse buttons mirror the device's three buttons.

| Action | Effect |
| --- | --- |
| Left click | Pause or resume rotation, holding the current screen |
| Right click / scroll | Step to the next or previous screen |
| Middle click | Refresh now |
| Hover | Tooltip with all four values at once |

Stepping works while paused, so you can park the widget on one statistic.

## Settings

```bash
omarchy bar set kravens.btclock rotateSeconds 21
omarchy bar set kravens.btclock refreshSeconds 60
omarchy bar set kravens.btclock cells 7
omarchy bar set kravens.btclock mode dark
omarchy bar set kravens.btclock currency USD
```

| Key | Default | Values |
| --- | --- | --- |
| `rotateSeconds` | `21` | 2–3600, seconds each screen is shown |
| `refreshSeconds` | `60` | 15–3600, seconds between fetches |
| `cells` | `7` | 3–12 panels |
| `mode` | `dark` | `dark` (dark panels, light text) or `light` (inverted) |
| `currency` | `USD` | `USD` `EUR` `GBP` `JPY` `CHF` `CAD` `AUD` |

Moscow time follows the selected currency — sats per unit of *that* fiat, as on
the real device — so with `currency EUR` it is sats per euro, not per dollar.

Colours come from the active Omarchy theme, so the panels follow whatever theme
is applied.

## Network access

Every request is an unauthenticated HTTPS `GET` to one of two fixed origins.
There are no credentials anywhere in this plugin, so nothing is ever sent.

| Endpoint | Purpose |
| --- | --- |
| `https://mempool.space/api/blocks/tip/height` | Block height |
| `https://mempool.space/api/v1/fees/recommended` | Fee rates |
| `https://mempool.space/api/v1/prices` | Prices in all seven currencies |
| `https://api.kraken.com/0/public/Ticker?pair=XBTUSD` | USD price, only if the mempool.space price call fails |

These are the same sources the [BTClock firmware](https://git.btclock.dev)
uses in its `dataSource=1` mode. One fetch happens per `refreshSeconds` per monitor.

Requests are made with a fixed HTTPS scheme, no redirect following, a connect
and total timeout, a response size ceiling, and proxies disabled.

## Files and state

**This plugin writes no files.** `bin/btc-status` fetches, validates and prints
one JSON line to stdout on each run; nothing is cached to disk, and no state
persists between invocations or across a restart. Settings live where every
Omarchy widget's settings live, in `~/.config/omarchy/shell.json`, managed by
`omarchy bar set`.

It does not read or modify any Hyprland configuration, any other plugin's
files, or anything else outside its own directory.

## Removing

```bash
omarchy plugin remove kravens.btclock
```

That removes the plugin directory and its bar entry. Because the plugin writes
no files, keeps no cache and holds no credentials, nothing else survives —
there is nothing left to clean up by hand, and no background process to stop.

## Running the data helper by hand

`bin/btc-status` is a standalone script and useful for checking the data path
without the shell:

```bash
bash bin/btc-status | jq .
```

It prints `{"ok":false}` and exits non-zero when the network is unavailable.
When a fetch fails while the widget is running, the last good numbers stay on
screen dimmed rather than the widget going blank.

## Credits

The screens, the panel layout and the formatting conventions (space-grouped
digits, Moscow time as sats per unit of the selected fiat, the compact price
suffix) all come from BTClock. Buy the hardware or build your own at
[btclock.store](https://btclock.store); the firmware is at
[git.btclock.dev](https://git.btclock.dev).

No BTClock code is used or vendored here — this is an independent
implementation for the Omarchy bar.

## Licence

MIT — see [LICENSE](LICENSE).
