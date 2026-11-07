# Setup guide: from IPA to your family on the map

HomeFind is only the app. Locations live on your own **[Dawarich](https://dawarich.app) server**, so you need one of those first. If you already run Dawarich (1.13 or newer, tested with **1.22.0**), skip to step 3.

## What you need

- iPhones with **iOS 26 or newer** (one per person)
- A computer that runs all the time (NAS, mini PC, home server) with **Docker**
- A free Apple ID for sideloading
- A way for the iPhones to reach the server when they are not at home – a VPN such as WireGuard, or a reverse proxy/tunnel with HTTPS. Background updates only work if the phone can reach the server from anywhere.

## 1. Set up Dawarich with Docker

Official guide: <https://dawarich.app/docs/getting-started/installation>

Short version:

```bash
mkdir -p /srv/dawarich && cd /srv/dawarich
curl -LO https://raw.githubusercontent.com/Freika/dawarich/master/docker/docker-compose.yml
cat > .env <<'EOT'
POSTGRES_PASSWORD=<long random password>
DATABASE_PASSWORD=<same password>
SECRET_KEY_BASE=<output of: openssl rand -hex 64>
APPLICATION_HOSTS=localhost,find.example.com,<server-ip>
TIME_ZONE=Europe/Berlin
EOT
docker compose up -d
```

Check that it is up: `curl http://<server-ip>:3000/api/v1/health` → `{"status":"ok"}`.

Notes:
- `APPLICATION_HOSTS` must contain every host name or IP the app uses to reach the server, otherwise Rails rejects the request.
- Self-hosted Dawarich has the **Family** feature enabled for all users – that is what HomeFind uses for sharing.
- For access from outside, put Dawarich behind HTTPS (Caddy, nginx, Cloudflare Tunnel …) or use a VPN. Plain HTTP is only allowed by the app for local network addresses.

## 2. Create accounts and a family

1. Open `http://<server-ip>:3000`, create an account for every person (or let them sign up, if registration is open).
2. One person opens **Family** in the web interface, creates a family and invites the others by email address.
3. The others accept the invitation (link in the email, or in the web interface under *Family*).

Dawarich allows **one family per account**, and sharing is always with the whole family. HomeFind shows this honestly: "Share My Location" means "share with my family".

## 3. Install the app

1. Download `HomeFind-<version>.ipa` from the releases page – or build it yourself with `./build-ipa.sh` (see README).
2. Install it with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io). A free Apple ID is enough; the app has to be refreshed every 7 days (SideStore does that on the phone).

## 4. Sign in

Open HomeFind → *Continue* → enter the server address and either email + password (the app exchanges them once for your API key and does not store the password) or the API key from the web interface (*Settings* → *API key*).

Then allow location access. Choose **Always** if your family should see you while the app is closed – HomeFind only sends on significant location changes and visits in the background, so the battery impact is small.

**More devices of your own** (iPad, second iPhone): on the first device go to *Devices* → **+** → *Show code*, then on the new device tap *Scan QR Code* on the sign-in screen. Under *Me* you choose which device provides "My Location".

## 5. Share

- *People* → **+** → pick a family member → *Share for One Hour* / *Until End of Day* / *Indefinitely*.
- *Ask to Follow Location* on a person who does not share yet; they get a notification the next time their app checks the server and can accept or decline.
- *Me* → *Share My Location* is the main switch.

## How updates work (no push)

There is no push service (that would need a paid Apple developer account and an extra relay). Instead:

- While the app is open it asks the server every 15 seconds.
- In the background iOS wakes HomeFind on significant location changes, visits and region events, and from time to time for a background refresh. At those moments the app sends its own location, checks the family, shows notifications for new requests and evaluates your location alerts.

So in the background, updates arrive with a delay of minutes, not seconds – similar to how often Apple's own app refreshes when nobody is looking.

## Backups and privacy

- Everything is in the Dawarich database (Docker volume `dawarich_db_data`). Back it up like any PostgreSQL volume.
- Dawarich keeps every point it receives as history in your account. You can delete history in the web interface. Family members only see your **latest** point while you share (HomeFind never turns on history sharing).
- Map tiles and – if enabled – place names and directions come from Apple. You can switch off Apple place-name lookups in *Me* → *Privacy*.
