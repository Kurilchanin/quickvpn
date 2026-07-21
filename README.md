# QuickVPN — TON-native VPN nodes

Decentralized VPN over TON ADNL. Anyone can run an **exit node** and earn for
serving traffic — no upfront funds, the node earns and pays its own withdrawal
gas out of earnings. Payments settle through a **hub** over TON payment channels.

## Install an exit node (one command)

```sh
curl -fsSL https://raw.githubusercontent.com/Kurilchanin/quickvpn/main/install.sh | sudo bash
```

The installer auto-detects your architecture and public IP, downloads the
binary, generates keys, opens the firewall, installs a systemd service, and
starts it. When it finishes it prints your **web panel URL + token** — open it
to see status, set your traffic price, and withdraw earnings.

Supported: Linux `amd64` / `arm64`. Run as root (the installer uses `sudo`).

## Run the payment hub (owner only)

```sh
curl -fsSL https://raw.githubusercontent.com/Kurilchanin/quickvpn/main/install.sh | sudo bash -s -- --role hub
```

## Downloads

Prebuilt binaries are attached to each [release](../../releases/latest):
`ton-vpn-node-{amd64,arm64}`, `ton-vpn-hub-{amd64,arm64}`.

_Testnet preview._
