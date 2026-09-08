# sk8-infrastructure

Infrastruktur-Repository der SK8-Plattform: lokale Entwicklungsumgebung mit Docker Compose, Datenbank-Bootstrap, Vorlagen für Umgebungsvariablen und die Railway-Einrichtung für alle sechs Repositories.

Stand: 7. September 2026. Grundlage sind die Architekturentscheidungen in `sk8-docs/content/adr/` – insbesondere ADR-001 (Workspace), ADR-005 (Datenbank und Deployment), ADR-006 (API-Zugriff), ADR-007 (Qualität) und ADR-008 (Konventionen).

## Zweck

- **Eine Datenbank für alle Dienste:** PostgreSQL 16 im Container mit den Datenbanken `sk8_backend`, `sk8_docs` sowie den Testdatenbanken `sk8_backend_test` und `sk8_docs_test`.
- **Ein Befehl zum Starten:** `make up` startet Postgres; `make up-full` baut und startet zusätzlich Backend, Docs und die drei Frontends aus den Nachbar-Repos.
- **Vorlagen statt Rätselraten:** `env/*.env.example` dokumentiert jede Umgebungsvariable je Dienst mit einer Zeile Erklärung.
- **Railway aus einer Hand:** `railway/README.md` beschreibt Projekt, Environments, Services und Variablen; `scripts/db-bootstrap.sh` legt die Datenbanken auf Railway an.

Was hier **nicht** liegt: Anwendungscode, Dockerfiles und `railway.json`. Die gehören in das jeweilige Repo, weil jedes Repo genau ein Deploy-Artefakt ist (ADR-001, ADR-005).

## Architekturüberblick

Sechs Repositories liegen als Geschwister in einem gemeinsamen Workspace-Verzeichnis, das selbst kein Git-Repo ist (ADR-001):

| Repo | Inhalt | Technik | Lokaler Port |
|---|---|---|---|
| `sk8-backend` | REST-API, Datenhaltung, KI-Engine, Telemetrie | Symfony 7.4 LTS, PHP 8.5, FrankenPHP, Doctrine | 8000 |
| `sk8-docs` | Projektdokumentation, ADRs, Feature-Einträge | Symfony 7.4 LTS, FrankenPHP | 8001 |
| `sk8-skate` | Skate-Sessions und Tricks | React 19, Vite, TanStack, Tailwind (PWA) | 5173 |
| `sk8-nutrition` | Ernährung, Etiketten-Scan | React 19, Vite, TanStack, Tailwind (PWA) | 5174 |
| `sk8-habits` | Gewohnheiten | React 19, Vite, TanStack, Tailwind (PWA) | 5175 |
| `sk8-infrastructure` | Dieses Repo: Compose, Skripte, Railway | Bash, Docker Compose, Make | – |

```mermaid
flowchart LR
    subgraph frontends [Frontends – React-PWAs]
        skate["sk8-skate<br/>:5173"]
        nutrition["sk8-nutrition<br/>:5174"]
        habits["sk8-habits<br/>:5175"]
    end

    backend["sk8-backend<br/>Symfony · :8000"]
    docs["sk8-docs<br/>Symfony · :8001"]
    pg[("PostgreSQL 16<br/>:5432")]

    skate -- "REST + X-Api-Key" --> backend
    nutrition -- "REST + X-Api-Key" --> backend
    habits -- "REST + X-Api-Key" --> backend
    backend -- "sk8_backend<br/>(Tests: sk8_backend_test)" --> pg
    docs -- "sk8_docs<br/>(Tests: sk8_docs_test)" --> pg

    infra["sk8-infrastructure<br/>Compose · Skripte · Railway"]
    infra -. "stellt bereit" .-> pg
```

Der Vertrag zwischen Backend und Frontends ist die OpenAPI-Spezifikation des Backends; geteilten Code gibt es nicht (ADR-001). Der Anthropic-Key existiert nur im Backend (ADR-010).

## Voraussetzungen

| Werkzeug | Zweck | Installation |
|---|---|---|
| Docker Desktop mit Compose v2 | Postgres-Container, optional der komplette Verbund | <https://www.docker.com/products/docker-desktop/> |
| git mit SSH-Zugang zu GitHub | Repos klonen, Hooks | `brew install git` |
| make | Kurzbefehle (`make up`, `make check`, …) | Xcode Command Line Tools |
| psql (optional) | Direkter Datenbankzugriff, `db-bootstrap.sh` | `brew install libpq && brew link --force libpq` |
| shellcheck (optional) | Skript-Prüfung in Hook und `make check`; ohne Installation wird das Docker-Image `koalaman/shellcheck:stable` verwendet | `brew install shellcheck` |

## Lokale Einrichtung Schritt für Schritt

1. **Workspace anlegen und dieses Repo klonen.** Das Workspace-Verzeichnis ist kein Git-Repo, die Repos liegen darin nebeneinander:

   ```bash
   mkdir -p ~/init-project && cd ~/init-project
   git clone git@github.com:konradthiemann/sk8-infrastructure.git
   cd sk8-infrastructure
   ```

2. **Restliche Repos klonen und Hooks aktivieren.** Das Skript klont nur, was fehlt, und setzt in jedem Repo mit `.githooks/` die Option `core.hooksPath`. Es kann jederzeit erneut laufen:

   ```bash
   make setup-workspace      # entspricht scripts/setup-workspace.sh
   ```

3. **Dieses Repo einrichten.** Aktiviert den Pre-Commit-Hook, legt `.env` aus `.env.example` an und prüft die Werkzeuge:

   ```bash
   make setup                # entspricht scripts/setup.sh
   ```

4. **Port prüfen.** Läuft auf dem Rechner bereits ein PostgreSQL auf 5432 (z. B. per Homebrew), in `.env` einen anderen Host-Port eintragen – `.env` ist ignoriert und rein lokal:

   ```bash
   lsof -nP -iTCP:5432 -sTCP:LISTEN        # belegt?
   echo 'POSTGRES_PORT=5433' > .env        # dann ausweichen
   ```

   Die Anwendungs-Repos verwenden in ihren `.env.local`-Dateien denselben Port.

5. **Postgres starten.** Wartet, bis der Container gesund ist, und gibt die drei Verbindungs-URLs aus:

   ```bash
   make up                   # entspricht scripts/dev-up.sh
   ```

   Beim ersten Start legt `postgres/init/01-databases.sh` die Datenbanken `sk8_docs` und `sk8_backend_test` an; `sk8_backend` kommt vom Image (`POSTGRES_DB`). Zugangsdaten: Benutzer `sk8`, Passwort `sk8`.

6. **Dienste lokal verbinden.** Standardweg laut ADR-005: Postgres im Container, Backend und Docs mit `symfony serve`, Frontends mit `pnpm dev`.

   ```bash
   # Backend
   cp ../sk8-infrastructure/env/backend.env.example ../sk8-backend/.env.local
   (cd ../sk8-backend && symfony serve --port=8000)

   # Docs
   cp ../sk8-infrastructure/env/docs.env.example ../sk8-docs/.env.local
   (cd ../sk8-docs && symfony serve --port=8001)

   # Frontends (Port steht in der jeweiligen vite.config.ts)
   cp ../sk8-infrastructure/env/frontend.env.example ../sk8-skate/.env.local
   (cd ../sk8-skate && pnpm dev)
   ```

   In den kopierten Dateien `APP_SECRET` setzen (`openssl rand -hex 16`) und bei abweichendem `POSTGRES_PORT` die `DATABASE_URL` anpassen.

7. **Optional: alles im Container.** Baut die Images aus den Nachbar-Repos (setzt deren Dockerfiles voraus) und startet den gesamten Verbund:

   ```bash
   make up-full              # entspricht scripts/dev-up.sh --full
   make down                 # stoppt alles, Daten bleiben erhalten
   ```

## Ports

| Dienst | Lokaler Port | Im Compose-Verbund | Bemerkung |
|---|---|---|---|
| postgres | 5432 | `sk8-postgres:5432` | Host-Port per `POSTGRES_PORT` änderbar |
| backend | 8000 | `backend:8000` | `symfony serve --port=8000` oder Profil `full` |
| docs | 8001 | `docs:8000` | Container lauscht intern auf 8000 |
| skate | 5173 | `skate:80` | Vite-Dev-Server oder Caddy im Container |
| nutrition | 5174 | `nutrition:80` | |
| habits | 5175 | `habits:80` | |

Innerhalb des Compose-Netzes erreichen Backend und Docs die Datenbank unter `postgres:5432`; vom Host aus unter `127.0.0.1:${POSTGRES_PORT}`.

## Umgebungsvariablen

Die Vorlagen in `env/` sind die Referenz für alle Dienste. Jede Variable trägt einen Kommentar, der ihren Zweck erklärt.

| Datei | Zieldienst | Wohin kopieren |
|---|---|---|
| `env/backend.env.example` | sk8-backend | `sk8-backend/.env.local` (lokal) bzw. Railway-Variablen |
| `env/docs.env.example` | sk8-docs | `sk8-docs/.env.local` (lokal) bzw. Railway-Variablen |
| `env/frontend.env.example` | sk8-skate, sk8-nutrition, sk8-habits | `<repo>/.env.local` (lokal) bzw. Railway-Variablen (Build-Zeit) |
| `.env.example` | dieses Repo | `.env` (nur `POSTGRES_PORT`) |

Regeln (ADR-005, ADR-006, ADR-010):

- `.env` im Anwendungs-Repo enthält nur ungefährliche Defaults, `.env.local` ist ignoriert; produktive Werte stehen ausschließlich in Railway.
- `APP_API_KEY` (Backend) und `VITE_API_KEY` (Frontends) müssen übereinstimmen; pro Environment ein eigener Wert.
- `ANTHROPIC_API_KEY` bleibt lokal leer – KI-Endpunkte antworten dann mit 503, alles andere funktioniert.
- Frontends kennen weder Anthropic-Key noch Modellnamen.

Welche Variable auf welchem Service gesetzt wird:

| Variable | backend | docs | skate / nutrition / habits |
|---|:-:|:-:|:-:|
| `APP_ENV`, `APP_SECRET`, `DATABASE_URL` | ✓ | ✓ | |
| `PORT` (Railway) | ✓ | ✓ | |
| `DEFAULT_URI` | ✓ | ✓ | |
| `APP_API_KEY`, `CORS_ALLOW_ORIGIN` | ✓ | | |
| `ANTHROPIC_API_KEY`, `AI_MODEL_VISION`, `AI_MODEL_TEXT` | ✓ | | |
| `MESSENGER_TRANSPORT_DSN` | ✓ | | |
| `VITE_API_URL`, `VITE_API_KEY`, `VITE_TELEMETRY` | | | ✓ (Build-Zeit) |

Die konkreten Werte je Environment stehen in der Variablen-Matrix in [`railway/README.md`](railway/README.md).

## Betrieb

### Logs

```bash
make logs                                   # alle laufenden Container, folgend
docker compose logs --tail 100 postgres     # nur Postgres
railway logs --service backend --lines 200  # Railway (siehe railway/README.md)
```

Backend und Docs loggen als JSON nach stdout (Monolog), Railway sammelt diese Ausgabe ein (ADR-002).

### Datenbankzugriff

```bash
make psql          # psql auf sk8_backend
make psql-docs     # psql auf sk8_docs
make psql-test     # psql auf sk8_backend_test
```

Oder vom Host mit dem lokalen Client: `psql "postgresql://sk8:sk8@127.0.0.1:5432/sk8_backend"`.

### Migrationen

Migrationen gehören zum jeweiligen Anwendungs-Repo (Doctrine Migrations) und laufen beim Container-Start im Entrypoint (`doctrine:migrations:migrate -n`, ADR-005). Lokal mit `symfony serve` werden sie von Hand ausgeführt:

```bash
cd ../sk8-backend
php bin/console doctrine:migrations:status
php bin/console doctrine:migrations:migrate -n
php bin/console doctrine:migrations:migrate -n --env=test   # Testdatenbank sk8_backend_test
```

Neue Migration nach Entity-Änderung: `php bin/console make:migration`, danach Datei prüfen und committen.

### Backups

Lokal genügt ein `pg_dump` in das ignorierte Verzeichnis `backups/`:

```bash
make backup        # sk8_backend und sk8_docs als pg_dump -Fc nach backups/
```

Wiederherstellen in eine leere Datenbank:

```bash
docker compose exec -T postgres pg_restore -U sk8 -d sk8_backend --clean --if-exists < backups/sk8_backend-<zeitstempel>.dump
```

Auf Railway übernimmt der Postgres-Service Volume-Backups (Dashboard → Postgres → Backups); zusätzlich lässt sich `pg_dump` gegen die `DATABASE_PUBLIC_URL` ausführen, siehe `railway/README.md`.

### Datenbank zurücksetzen

```bash
make db-reset      # fragt nach, löscht das Volume und startet Postgres neu
```

Danach laufen die Init-Skripte erneut; die Migrationen der Anwendungen müssen anschließend neu ausgeführt werden.

## Railway

Kurzfassung – die vollständige Anleitung mit allen CLI-Befehlen steht in [`railway/README.md`](railway/README.md).

| Element | Wert |
|---|---|
| Projekt | `sk8` |
| Environment `production` | Branch `main` – täglich genutzte Apps |
| Environment `development` | Branch `develop` – Vorschau neuer Features |
| Services je Environment | `postgres`, `backend`, `docs`, `skate`, `nutrition`, `habits` |
| Datenbanken | Eine Postgres-Instanz je Environment mit `sk8_backend` und `sk8_docs` (`scripts/db-bootstrap.sh`) |
| Build | Dockerfile aus dem jeweiligen Repo, Konfiguration in dessen `railway.json` |
| Deploy-Schutz | Option „Wait for CI" – rote GitHub-Actions verhindern den Deploy (ADR-007) |

Railway-Ressourcen verursachen laufende Kosten und werden deshalb erst nach ausdrücklicher Freigabe angelegt (ADR-005).

## Qualitätssicherung

Alle Prüfungen laufen über ein Skript, damit Hook, Makefile und CI identisch sind:

```bash
make check         # docker compose --profile full config -q, bash -n, shellcheck
```

- **Pre-Commit-Hook** `.githooks/pre-commit` ruft dieselbe Prüfung auf; aktiviert durch `make setup` (`git config core.hooksPath .githooks`).
- **shellcheck** wird lokal verwendet, wenn es installiert ist; sonst weicht `make check` auf das offizielle Docker-Image `koalaman/shellcheck:stable` aus.
- **GitHub Actions** `.github/workflows/ci.yml` installiert shellcheck und führt `make check` auf `ubuntu-latest` aus; dort ist shellcheck verpflichtend.
- **Konventionen** (ADR-008): Code, Bezeichner und Kommentare Englisch; Dokumentation Deutsch; Commits als Conventional Commits, Betreff ≤ 50 Zeichen, imperativ, kleingeschrieben, ohne Trailer.

## Verzeichnisstruktur

```text
.
├── .editorconfig               Einheitliche Editor-Einstellungen
├── .env.example                Vorlage für .env (POSTGRES_PORT)
├── .githooks/pre-commit        Versionierter Git-Hook → scripts/check.sh
├── .github/workflows/ci.yml    CI: shellcheck + make check
├── Makefile                    Kurzbefehle (make help)
├── docker-compose.yml          Postgres (Standard) und Profil "full" für alle Dienste
├── env/                        Vorlagen für Umgebungsvariablen je Dienst
├── postgres/init/              Init-Skripte des Postgres-Containers (weitere Datenbanken)
├── railway/README.md           Railway-Einrichtung Schritt für Schritt, Variablen-Matrix
└── scripts/
    ├── check.sh                Alle statischen Prüfungen (Hook, make check, CI)
    ├── db-bootstrap.sh         Datenbanken auf Railway anlegen
    ├── dev-up.sh / dev-down.sh Compose-Wrapper, wartet auf gesunden Postgres
    ├── setup.sh                Hooks, .env, Werkzeug-Check für dieses Repo
    └── setup-workspace.sh      Fehlende sk8-* Repos klonen, Hooks aktivieren
```
