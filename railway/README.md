# Railway-Einrichtung

Schritt-für-Schritt-Anleitung für das Railway-Projekt `sk8` mit den Environments `production` und `development` (ADR-005). Stand: 7. September 2026.

> **Kosten:** Ab Schritt 2 entstehen kostenpflichtige Ressourcen (Postgres-Volume, Service-Laufzeit). Diese Anleitung wird erst ausgeführt, nachdem der Entwickler das ausdrücklich freigegeben hat. Vorbereitet ist alles; von sich aus legt nichts Ressourcen an.

## Zielbild

| Environment | Git-Branch | Services |
|---|---|---|
| `production` | `main` | `postgres`, `backend`, `docs`, `skate`, `nutrition`, `habits` |
| `development` | `develop` | dieselben sechs Services mit eigener Postgres-Instanz |

- Jedes Anwendungs-Repo bringt sein `Dockerfile` und eine `railway.json` mit (Builder `DOCKERFILE`, Healthcheck-Pfad, Restart-Policy `ON_FAILURE`).
- Umgebungsvariablen werden ausschließlich in Railway gesetzt; Secrets nie in Git.
- Die Frontends erhalten `VITE_*` zur Build-Zeit. Railway reicht Service-Variablen als Build-Argumente in den Dockerfile-Build, sofern das Dockerfile sie mit `ARG VITE_API_URL` usw. deklariert.
- Backend und Docs erreichen Postgres über das private Netz (`RAILWAY_PRIVATE_DOMAIN`), Browser erreichen Backend und Frontends über öffentliche Domains.

## Voraussetzungen

- Railway-Account; die GitHub-App von Railway ist einmalig für den Account `konradthiemann` autorisiert (Dashboard → Account Settings → Integrations → GitHub).
- Railway CLI in aktueller Version (die Befehle `railway environment edit`, `railway variable set` und `railway domain` setzen CLI 5.2x oder neuer voraus):

  ```bash
  brew install railway      # oder: railway upgrade
  railway --version
  ```

- `psql` lokal für `scripts/db-bootstrap.sh` (`brew install libpq && brew link --force libpq`).
- In allen fünf Anwendungs-Repos existiert der Branch `develop`, bevor das Development-Environment verknüpft wird (ADR-005).

Alle Befehle unten werden aus dem Verzeichnis `sk8-infrastructure` ausgeführt. `railway init` verknüpft dieses Verzeichnis mit dem Projekt; die Verknüpfung liegt in `~/.railway`, nicht im Repo.

## 1. Anmelden und Projekt anlegen

```bash
railway login
railway init --name sk8
railway status --json
```

`railway init` erzeugt das Projekt mit dem Environment `production` und verknüpft das aktuelle Verzeichnis. Bei mehreren Workspaces `--workspace <name>` ergänzen.

## 2. PostgreSQL anlegen

```bash
railway add --database postgres --json
railway service list --json
```

Railway legt den Service unter dem Namen `Postgres` an, zusammen mit Volume, TCP-Proxy und den Variablen `PGUSER`, `PGPASSWORD`, `PGHOST`, `PGPORT`, `PGDATABASE`, `DATABASE_URL` und `DATABASE_PUBLIC_URL`. Den Service anschließend in `postgres` umbenennen (Dashboard → Service → Settings → Service Name), damit die Namen mit ADR-005 und den Referenzvariablen unten übereinstimmen. Referenzen sind case-sensitiv.

`--json` ist Pflicht: Ohne die Option schreibt ein erfolgreicher Aufruf nichts nach stdout, und ein blinder zweiter Versuch legt eine zweite Datenbank an.

## 3. Datenbanken `sk8_backend` und `sk8_docs` anlegen

Die Instanz liefert nur die Standard-Datenbank `railway`. Das Bootstrap-Skript legt die beiden Anwendungs-Datenbanken idempotent an und verwendet dafür die öffentliche URL des TCP-Proxys:

```bash
railway variable list --service postgres --environment production --json   # Wert von DATABASE_PUBLIC_URL ablesen
scripts/db-bootstrap.sh 'postgresql://postgres:<passwort>@<host>.proxy.rlwy.net:<port>/railway'
```

Das Skript gibt die abgeleiteten Verbindungs-URLs mit maskiertem Passwort aus sowie die Referenzvariablen für Schritt 5. Es darf beliebig oft laufen.

## 4. App-Services anlegen und mit GitHub verbinden

Für jeden der fünf Services zuerst einen leeren Service anlegen:

```bash
for service in backend docs skate nutrition habits; do
  railway add --service "$service" --json
done
```

Dann das Repo verbinden – beim ersten Mal im Dashboard (Service → Settings → Source → „Connect Repo" → `konradthiemann/sk8-<name>`, Branch `main`), weil dort die GitHub-App-Freigabe abgefragt wird. Alternativ per CLI:

```bash
railway environment edit --environment production --service-config backend source.repo konradthiemann/sk8-backend
railway environment edit --environment production --service-config backend source.branch main
```

Builder, Healthcheck und Restart-Policy kommen aus der `railway.json` des Repos; in Railway ist dafür nichts weiter einzustellen. Kontrolle: `railway environment config --json`.

## 5. Variablen setzen (`production`)

Werte in einfachen Anführungszeichen übergeben, damit die Shell `${{…}}` nicht auswertet. Secrets über `--stdin`, damit sie nicht in der Shell-History landen.

**backend**

```bash
railway variable set \
  APP_ENV=prod \
  PORT=8000 \
  'DATABASE_URL=postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_backend?serverVersion=16&charset=utf8' \
  'MESSENGER_TRANSPORT_DSN=doctrine://default?auto_setup=0' \
  AI_MODEL_VISION=claude-haiku-4-5 \
  AI_MODEL_TEXT=claude-haiku-4-5 \
  'DEFAULT_URI=https://${{RAILWAY_PUBLIC_DOMAIN}}' \
  --service backend --environment production --skip-deploys

openssl rand -hex 16 | tr -d '\n' | railway variable set APP_SECRET --stdin --service backend --environment production --skip-deploys
openssl rand -hex 32 | tr -d '\n' | railway variable set APP_API_KEY --stdin --service backend --environment production --skip-deploys
```

`CORS_ALLOW_ORIGIN` folgt in Schritt 6, sobald die Frontend-Domains bekannt sind. `ANTHROPIC_API_KEY` wird erst gesetzt, wenn der Entwickler den Key bereitstellt (bis dahin antworten KI-Endpunkte mit 503, ADR-010):

```bash
printf '%s' "$ANTHROPIC_API_KEY" | railway variable set ANTHROPIC_API_KEY --stdin --service backend --environment production
```

**docs**

```bash
railway variable set \
  APP_ENV=prod \
  PORT=8000 \
  'DATABASE_URL=postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_docs?serverVersion=16&charset=utf8' \
  'DEFAULT_URI=https://${{RAILWAY_PUBLIC_DOMAIN}}' \
  --service docs --environment production --skip-deploys

openssl rand -hex 16 | tr -d '\n' | railway variable set APP_SECRET --stdin --service docs --environment production --skip-deploys
```

**skate, nutrition, habits**

`VITE_API_KEY` referenziert den Backend-Key, damit beide Werte nie auseinanderlaufen. `VITE_API_URL` folgt in Schritt 6.

```bash
for service in skate nutrition habits; do
  railway variable set \
    'VITE_API_KEY=${{backend.APP_API_KEY}}' \
    VITE_TELEMETRY=on \
    --service "$service" --environment production --skip-deploys
done
```

## 6. Domains erzeugen und Querverweise setzen

Je Service eine Railway-Domain erzeugen (eine pro Service ist kostenlos enthalten):

```bash
for service in backend docs skate nutrition habits; do
  railway domain --service "$service" --environment production --json
done
railway domain list --service backend --environment production --json
```

Mit den erzeugten Hostnamen die Querverweise setzen. Die CORS-Allowlist ist ein Regex über die drei Frontend-Origins (ADR-006):

```bash
railway variable set \
  'CORS_ALLOW_ORIGIN=^https://(skate-production-xxxx|nutrition-production-xxxx|habits-production-xxxx)\.up\.railway\.app$' \
  --service backend --environment production

for service in skate nutrition habits; do
  railway variable set VITE_API_URL=https://backend-production-xxxx.up.railway.app \
    --service "$service" --environment production
done
```

Diese letzten Aufrufe ohne `--skip-deploys`, damit alle Services mit vollständiger Konfiguration bauen. Frontends müssen nach jeder Änderung an `VITE_*` neu gebaut werden (`railway redeploy --service skate -y`), weil Vite die Werte einkompiliert.

## 7. Development-Environment anlegen

```bash
railway environment new development --duplicate production
for service in backend docs skate nutrition habits; do
  railway environment edit --environment development --service-config "$service" source.branch develop
done
```

`--duplicate` kopiert Services, Variablen und Quellen; das Development-Environment bekommt damit eine **eigene** Postgres-Instanz mit eigenem Volume. Danach anpassen:

1. Datenbanken auf der Development-Instanz anlegen: Schritt 3 mit `--environment development` wiederholen.
2. Domains erzeugen: Schritt 6 mit `--environment development` wiederholen und `CORS_ALLOW_ORIGIN`, `VITE_API_URL` auf die neuen Hostnamen setzen (`DEFAULT_URI` und `DATABASE_URL` bleiben als Referenzen unverändert gültig).
3. Eigene Secrets: `APP_SECRET` (backend, docs) und `APP_API_KEY` (backend) neu generieren – die Frontends folgen über die Referenz `${{backend.APP_API_KEY}}`.

## 8. „Wait for CI" aktivieren

Railway deployt einen Commit dann erst, wenn die GitHub-Actions des Repos grün sind (ADR-007). Für alle fünf App-Services in beiden Environments:

```bash
for env in production development; do
  for service in backend docs skate nutrition habits; do
    railway environment edit --environment "$env" --service-config "$service" source.checkSuites true
  done
done
```

Im Dashboard entspricht das dem Schalter „Wait for CI" unter Service → Settings → Source. Voraussetzung ist ein CI-Workflow in jedem Repo; ohne Check-Suite wartet Railway nicht.

## 9. Deployen und prüfen

Ein Push auf `main` bzw. `develop` löst den Deploy aus. Kontrolle:

```bash
railway deployment list --service backend --environment production --json
railway logs --service backend --environment production --lines 100
curl -fsS https://backend-production-xxxx.up.railway.app/api/health
curl -fsS https://docs-production-xxxx.up.railway.app/health
```

Ein Deploy gilt erst als erfolgreich, wenn die Deployment-Liste `SUCCESS` zeigt und der Healthcheck antwortet. Bei `FAILED` oder `CRASHED` zuerst die Build- und Runtime-Logs lesen; typische Ursachen sind fehlende Variablen (Symfony bricht beim Container-Start ab) oder eine nicht erreichbare Datenbank (Migrationen im Entrypoint schlagen fehl).

## Variablen-Matrix

`ref` steht für eine Railway-Referenzvariable, `secret` für einen generierten Wert (nie im Repo). Werte gelten je Environment; wo nur ein Wert steht, ist er in beiden Environments gleich.

### postgres

Vollständig von Railway verwaltet – keine eigenen Variablen. Genutzt werden `PGUSER`, `PGPASSWORD`, `RAILWAY_PRIVATE_DOMAIN` (per Referenz) und `DATABASE_PUBLIC_URL` (nur für `db-bootstrap.sh` und Backups).

### backend

| Variable | production | development |
|---|---|---|
| `APP_ENV` | `prod` | `prod` (kein Profiler auf öffentlichen URLs) |
| `APP_SECRET` | secret | eigenes secret |
| `PORT` | `8000` | `8000` |
| `DATABASE_URL` | ref: `postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_backend?serverVersion=16&charset=utf8` | identisch (zeigt auf die Development-Instanz) |
| `APP_API_KEY` | secret (`openssl rand -hex 32`) | eigenes secret |
| `CORS_ALLOW_ORIGIN` | Regex über die drei Production-Frontend-Domains | Regex über die drei Development-Frontend-Domains |
| `ANTHROPIC_API_KEY` | vom Entwickler, sobald vorhanden | leer oder eigener Key mit Kostenlimit |
| `AI_MODEL_VISION` | `claude-haiku-4-5` | `claude-haiku-4-5` |
| `AI_MODEL_TEXT` | `claude-haiku-4-5` | `claude-haiku-4-5` |
| `MESSENGER_TRANSPORT_DSN` | `doctrine://default?auto_setup=0` | identisch |
| `DEFAULT_URI` | ref: `https://${{RAILWAY_PUBLIC_DOMAIN}}` | identisch |

### docs

| Variable | production | development |
|---|---|---|
| `APP_ENV` | `prod` | `prod` |
| `APP_SECRET` | secret | eigenes secret |
| `PORT` | `8000` | `8000` |
| `DATABASE_URL` | ref: `postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_docs?serverVersion=16&charset=utf8` | identisch |
| `DEFAULT_URI` | ref: `https://${{RAILWAY_PUBLIC_DOMAIN}}` | identisch |

### skate, nutrition, habits (Build-Zeit)

| Variable | production | development |
|---|---|---|
| `VITE_API_URL` | `https://<backend-production-domain>` | `https://<backend-development-domain>` |
| `VITE_API_KEY` | ref: `${{backend.APP_API_KEY}}` | identisch (löst zum Development-Backend auf) |
| `VITE_TELEMETRY` | `on` | `true` |

## Betrieb auf Railway

| Aufgabe | Befehl |
|---|---|
| Logs | `railway logs --service backend --environment production --lines 200` |
| Deploy-Status | `railway deployment list --service backend --environment production --json` |
| Neu deployen ohne Commit | `railway redeploy --service skate --environment production -y` |
| Migrations-Status | `railway ssh --service backend --environment production -- php bin/console doctrine:migrations:status` |
| psql auf die Instanz | `railway connect postgres --environment production` |
| Backup | Dashboard → Postgres → Backups (Volume-Snapshots) oder `pg_dump -Fc "<DATABASE_PUBLIC_URL mit /sk8_backend>" > backups/sk8_backend-$(date +%Y%m%d).dump` |
| API-Key rotieren | `openssl rand -hex 32 \| tr -d '\n' \| railway variable set APP_API_KEY --stdin --service backend --environment production`, anschließend die drei Frontends neu bauen (`railway redeploy`) |
| Kosten prüfen | Dashboard → Workspace → Usage |

Migrationen laufen beim Container-Start (ADR-005). Schlägt eine Migration fehl, bleibt der alte Deploy aktiv; Ursache in den Deploy-Logs suchen, Migration im Repo korrigieren, erneut pushen.
