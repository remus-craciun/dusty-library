# Dusty Library

A self-hosted PDF book reader. A single Go binary serves a JSON API backed by
SQLite and the Flutter web client; the same Flutter code builds the Android and
iOS apps.

Features

- Upload PDF books from the app (mobile or web).
- Read online, or offline on mobile after a download. The reading position
  (the page and how far down it) is kept and synced across devices.
- Eye-friendly reader: text size (zoom) and page colour filters, including an
  "old paper" tint that mimics a faded paperback page, sepia and dark.
- Focus mode (toolbar button or reading settings): the blank page margins are
  trimmed so the paragraphs fill the whole width of the screen, pages flow as
  one continuous sheet, and the screen is kept awake while you read. The
  setting is per device. Edge taps (also in reading settings) move one screen
  back or forward when you tap the left or right 20% of the page. On the web,
  the arrow keys scroll the page.
- Progress bar per book in the library.
- Shelves: `Active` and `Completed` are built in; create, rename and delete your
  own shelves.
- Single-account server: registration is only possible while no account exists;
  afterwards only login is offered. Mobile asks for the server address first;
  the web client uses the origin it was served from. You stay signed in until
  you sign out.

## Layout

```
server/   Go API + embedded web build   (go 1.27, modernc.org/sqlite, no cgo)
app/      Flutter app for Android, iOS and web
Makefile  web -> embed -> go build pipeline
Dockerfile
```

## Build and run

Requirements: Go 1.27+, Flutter 3.47+ (for web/mobile builds).

```sh
make web      # flutter build web, copied into server/internal/web/dist
make server   # rebuild the web bundle if the app changed, then go build
make build    # both
make dev      # same web rebuild, then run the server (./data, port from .env)
make test     # go tests + flutter analyze + flutter tests
```

The web UI is compiled into the Go binary (`//go:embed`), so restarting the
server alone keeps serving the previous bundle. `make server` and `make dev`
rebuild the bundle whenever files under `app/lib`, `app/web` or `app/assets`
are newer than it. Each build stamps its id onto `flutter_bootstrap.js` and
`main.dart.js`, so the browser cannot keep showing an older bundle that it
cached under those names. After a restart, reload the page once.

The app name is "Dusty Library" on every platform (Android label, iOS bundle
name, desktop window titles, web manifest and page title). The launcher icon —
an open book with dust motes on the old-paper background — is generated for
all platforms from `app/assets/icon/` (`icon.svg` is the source; `icon.png`,
`icon_square.png` and `icon_foreground.png` are the raster inputs). After
changing the artwork, regenerate with:

```sh
cd app && dart run flutter_launcher_icons
```

Or with Docker:

```sh
docker build -t dusty-library .
docker run -p 8080:8080 -v dusty-data:/data dusty-library
```

Or with Docker Compose (reads `.env`):

```sh
cp .env.example .env   # or: make env
docker compose up -d --build
```

Server configuration (flags win over environment variables; `make dev` and
`docker compose` load `.env`, see [.env.example](.env.example)):

| Flag          | Env                      | Default     | Meaning                        |
| ------------- | ------------------------ | ----------- | ------------------------------ |
| `-addr`       | `DUSTY_ADDR`             | `:8080`     | Listen address                 |
| `-data`       | `DUSTY_DATA_DIR`         | `./data`    | SQLite DB and PDFs             |
| `-max-upload` | `DUSTY_MAX_UPLOAD_BYTES` | `536870912` | Maximum PDF size in bytes      |

Open `http://<server>:8080/` in a browser for the web client. On first visit
you will be asked to create the account; afterwards the same page shows the
login form.

### Coolify (Railpack)

The repo includes [`railpack.json`](railpack.json). Coolify's Railpack build
pack reads it, builds the Flutter web client, embeds that bundle in the Go
server, and starts the binary. Railpack is beta in Coolify and needs the
Docker Buildx plugin on the server that runs the build.

1. In Coolify, create an application from this Git repository and select branch `main`.
2. Set the build pack to **Railpack**. Leave the base directory as `/`.
3. Leave **Is it a static site?** off. Set the port to `8080`.
4. Add a domain and point it at port `8080`.
5. Under environment variables (runtime, not build-time), set:

   | Name | Value |
   | --- | --- |
   | `DUSTY_ADDR` | `:8080` |
   | `DUSTY_DATA_DIR` | `/data` |
   | `DUSTY_MAX_UPLOAD_BYTES` | `536870912` |

6. Under **Persistent Storage**, add a volume mount named `dusty-data` with destination `/data`. Leave the source path empty so Coolify creates a Docker volume. The SQLite database and uploaded PDFs live there; without this mount a redeploy wipes the library.
7. Optional health check path: `/api/status`.
8. Deploy. The first web build downloads Flutter and compiles the client, so the first deployment takes several minutes. When it is up, open the domain and create the account.

Back up the `/data` volume. Signing in on a phone uses the same public URL (for example `https://books.example.com`).

### Mobile apps

```sh
cd app
flutter run                     # on a connected device / emulator
flutter build apk --release     # Android
flutter build ipa               # iOS (macOS + Xcode)
```

On first launch the app asks for the server IP or domain (for example
`192.168.1.10:8080` or `https://books.example.com`), verifies it, then shows
register or login depending on whether the server already has an account.

For local development against the web client without rebuilding the server:

```sh
make dev                                         # terminal 1
cd app && flutter run -d chrome --web-port 3000  # terminal 2 (CORS is enabled on /api)
```

In that setup the web client takes its server from the page origin, so point
it at the Go server by running the web build through the server (`make build`)
rather than the Flutter dev server when you want to test the real flow.

## API overview

All endpoints are under `/api` and return JSON. Everything except `status`,
`register` and `login` requires `Authorization: Bearer <token>`.

| Method | Path                       | Purpose                                              |
| ------ | -------------------------- | ---------------------------------------------------- |
| GET    | `/api/status`              | `{registered: bool}` - register vs login             |
| POST   | `/api/auth/register`       | Create the single account (409 once one exists)      |
| POST   | `/api/auth/login`          | Returns `{token, user}`; tokens never expire         |
| POST   | `/api/auth/logout`         | Revokes the calling token                            |
| POST   | `/api/auth/logout-all`     | Revokes every token of the account                   |
| GET    | `/api/me`                  | Current user                                         |
| GET/PUT| `/api/settings`            | Reader settings `{zoom, filter}`                     |
| GET/POST | `/api/shelves`           | List / create shelves                                |
| PATCH/DELETE | `/api/shelves/{id}`  | Rename / delete custom shelves (built-ins are fixed) |
| GET/POST | `/api/books`             | List / upload (`multipart`: file, title, page_count, shelf_id) |
| GET/PATCH/DELETE | `/api/books/{id}` | Book details / move, rename, set page count / delete |
| GET    | `/api/books/{id}/file`     | PDF bytes (range requests supported)                 |
| PUT    | `/api/books/{id}/progress` | `{current_page, page_offset, updated_at}`; `page_offset` is 0..1 down the page. Last write (by timestamp) wins |

Any other path serves the embedded Flutter web build with SPA fallback.

## Data

`DUSTY_DATA_DIR` contains `dusty.db` (SQLite, WAL mode) and `books/<id>.pdf`.
Back up the whole directory.

Login tokens are opaque random values stored hashed in the `sessions` table.
They do not expire; a token stops working only when the user signs out (on
that device or everywhere), which deletes the session row.
