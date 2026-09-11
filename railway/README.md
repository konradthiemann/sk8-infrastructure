# Railway-Einrichtung

Schritt-für-Schritt-Anleitung für das Railway-Projekt `sk8` mit den Environments `production` und `development` (ADR-005). Stand: 9. September 2026.

> **Kosten:** Ab Schritt 2 entstehen kostenpflichtige Ressourcen (Postgres-Volume, Service-Laufzeit). Diese Anleitung wird erst ausgeführt, nachdem der Entwickler das ausdrücklich freigegeben hat. Vorbereitet ist alles; von sich aus legt nichts Ressourcen an. Details und Kostenarten: Abschnitt „Kosten" unten.

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
- Railway CLI, geprüft gegen Version **5.45.5** – jeder Befehl in dieser Anleitung wurde gegen `railway <befehl> --help` dieser Version verifiziert:

  ```bash
  brew install railway      # oder: railway upgrade
  railway --version
  ```

  CLI-Oberflächen sind keine stabile Spezifikation: Unterbefehle kommen hinzu oder ändern ihren Namen zwischen Versionen. Nach jedem `railway upgrade` vor dem nächsten produktiven Einsatz die hier verwendeten Befehle erneut gegen `--help` prüfen, statt sich auf diese Anleitung zu verlassen.
- `railway usage` steht in 5.45.5 zur Verfügung (Unterbefehle `projects`, `limit status`, `limit set`, `limit update`, `limit remove`) – Ausgabengrenzen lassen sich damit direkt per CLI setzen (Abschnitt „Kosten" unten); das Dashboard (Workspace → Usage) bleibt eine gleichwertige Alternative.
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

Das Skript gibt die abgeleiteten Verbindungs-URLs mit maskiertem Passwort aus sowie die Referenzvariablen für Schritt 6. Es darf beliebig oft laufen.

## 4. App-Services anlegen

Für jeden der fünf Services zunächst nur einen leeren Service anlegen – **ohne** Quelle:

```bash
for service in backend docs skate nutrition habits; do
  railway add --service "$service" --json
done
```

Die Quelle (GitHub-Repo) wird bewusst noch nicht verbunden. Das passiert erst in Schritt 8, nachdem Domain, Variablen und „Wait for CI" gesetzt sind: der erste Build soll die endgültige Konfiguration sehen, nicht einen zwangsläufig fehlschlagenden Zwischenstand ohne `DATABASE_URL`.

## 5. Domains erzeugen

Solange kein Image existiert, braucht `railway domain` den Ziel-Port explizit – sonst müsste Railway ihn aus einem noch nicht vorhandenen Image erraten:

```bash
for service in backend docs; do
  railway domain --service "$service" --environment production --port 8000 --json
done
for service in skate nutrition habits; do
  railway domain --service "$service" --environment production --port 80 --json
done
railway domain list --service backend --environment production --json
```

Die erzeugten Hostnamen werden in Schritt 6 für `CORS_ALLOW_ORIGIN` und `VITE_API_URL` gebraucht.

## 6. Variablen setzen (`production`)

Werte in einfachen Anführungszeichen übergeben, damit die Shell `${{…}}` nicht auswertet. Secrets über `--stdin`, damit sie nicht in der Shell-History landen. Alle Aufrufe in diesem Schritt laufen mit `--skip-deploys` – ein Build kann ohnehin erst starten, wenn in Schritt 8 die Quelle verbunden wird.

**backend**

```bash
railway variable set \
  APP_ENV=prod \
  PORT=8000 \
  'DATABASE_URL=postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_backend?serverVersion=16&charset=utf8' \
  'MESSENGER_TRANSPORT_DSN=doctrine://default?auto_setup=0' \
  SYMFONY_TRUSTED_PROXIES=REMOTE_ADDR \
  'DEFAULT_URI=https://${{RAILWAY_PUBLIC_DOMAIN}}' \
  'CORS_ALLOW_ORIGIN=^https://(skate-production-xxxx|nutrition-production-xxxx|habits-production-xxxx)\.up\.railway\.app$' \
  --service backend --environment production --skip-deploys

openssl rand -hex 16 | tr -d '\n' | railway variable set APP_SECRET --stdin --service backend --environment production --skip-deploys
openssl rand -hex 32 | tr -d '\n' | railway variable set APP_API_KEY --stdin --service backend --environment production --skip-deploys
```

Die Platzhalter `skate-production-xxxx` usw. durch die tatsächlichen Hostnamen aus Schritt 5 ersetzen (`railway domain list --service skate --environment production --json`).

`AI_MODEL_VISION`/`AI_MODEL_TEXT` werden hier bewusst **nicht** gesetzt – erst mit dem ersten KI-Feature, sobald die Modellkennung gegen die aktuelle Anthropic-Dokumentation geprüft ist (ADR-010). Bis dahin bleiben sie unbesetzt; das Backend antwortet auf KI-Endpunkte mit `503` (siehe „Was passiert, wenn eine Variable fehlt" unten). `ANTHROPIC_API_KEY` wird erst gesetzt, wenn der Entwickler den Key bereitstellt:

```bash
printf '%s' "$ANTHROPIC_API_KEY" | railway variable set ANTHROPIC_API_KEY --stdin --service backend --environment production --skip-deploys
```

**docs**

```bash
railway variable set \
  APP_ENV=prod \
  PORT=8000 \
  'DATABASE_URL=postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_docs?serverVersion=16&charset=utf8' \
  SYMFONY_TRUSTED_PROXIES=REMOTE_ADDR \
  'DEFAULT_URI=https://${{RAILWAY_PUBLIC_DOMAIN}}' \
  --service docs --environment production --skip-deploys

openssl rand -hex 16 | tr -d '\n' | railway variable set APP_SECRET --stdin --service docs --environment production --skip-deploys
```

**skate, nutrition, habits**

`VITE_API_KEY` referenziert den Backend-Key, damit beide Werte nie auseinanderlaufen. `VITE_TELEMETRY` steht in **beiden** Environments auf `on` – das Frontend prüft nur, ob der Wert `off` ist (`sk8-skate/src/lib/env.ts`), ein gemischter `true`/`on`-Wert wäre technisch unschädlich, aber unnötig inkonsistent.

```bash
for service in skate nutrition habits; do
  railway variable set \
    'VITE_API_KEY=${{backend.APP_API_KEY}}' \
    VITE_TELEMETRY=on \
    PORT=80 \
    VITE_API_URL=https://backend-production-xxxx.up.railway.app \
    --service "$service" --environment production --skip-deploys
done
```

Den Platzhalter `backend-production-xxxx` durch den Backend-Hostnamen aus Schritt 5 ersetzen.

## 7. „Wait for CI" aktivieren

Railway deployt einen Commit dann erst, wenn die GitHub-Actions des Repos grün sind (ADR-007). Für alle fünf App-Services in `production`:

```bash
for service in backend docs skate nutrition habits; do
  railway environment edit --environment production --service-config "$service" source.checkSuites true
done
```

`development` existiert an dieser Stelle noch nicht (Schritt 9) und wird per `--duplicate production` erzeugt – das kopiert diese Einstellung automatisch mit, ein zweiter Lauf für `development` ist nicht nötig.

Im Dashboard entspricht das dem Schalter „Wait for CI" unter Service → Settings → Source. Voraussetzung ist ein CI-Workflow in jedem Repo; ohne Check-Suite wartet Railway nicht. Kontrolle: `railway environment config --json`.

> Der konkrete Dot-Pfad `source.checkSuites` ist bislang **nicht** an einer laufenden Railway-Installation verifiziert (nur aus der CLI-Hilfe abgeleitet). Vor dem produktiven Einsatz einmal im Dashboard schalten, danach `railway environment config --environment production --json` lesen und prüfen, ob der Pfad tatsächlich `source.checkSuites` heißt; falls abweichend, diese Anleitung nachziehen.

## 8. Quelle verbinden

```bash
for service in backend docs skate nutrition habits; do
  railway service source connect --repo "konradthiemann/sk8-$service" --branch main --service "$service"
done
```

Beim ersten Aufruf fragt Railway die GitHub-App-Autorisierung ab, falls sie noch nicht erteilt ist (Dashboard → Account Settings → Integrations → GitHub); danach funktioniert der CLI-Weg für jeden weiteren Service ohne Rückfrage. Dies ist der erste Build jedes Services – er läuft mit vollständiger Konfiguration (Domain, Variablen, Wait-for-CI bereits gesetzt), nicht mit einem Zwischenstand.

## 9. Development-Environment anlegen

```bash
railway environment new development --duplicate production
```

`--duplicate` kopiert Services, Variablen, Quellen und die in Schritt 7 gesetzte „Wait for CI"-Konfiguration; das Development-Environment bekommt damit eine **eigene** Postgres-Instanz mit eigenem Volume. Danach anpassen:

1. Branch je Service auf `develop` umstellen:
   ```bash
   for service in backend docs skate nutrition habits; do
     railway environment edit --environment development --service-config "$service" source.branch develop
   done
   ```
2. Datenbanken auf der Development-Instanz anlegen: Schritt 3 mit `--environment development` wiederholen.
3. Domains erzeugen: Schritt 5 mit `--environment development` wiederholen und `CORS_ALLOW_ORIGIN`, `VITE_API_URL` auf die neuen Hostnamen setzen (`DEFAULT_URI` und `DATABASE_URL` bleiben als Referenzen unverändert gültig).
4. Eigene Secrets: `APP_SECRET` (backend, docs) und `APP_API_KEY` (backend) neu generieren – die Frontends folgen automatisch über die Referenz `${{backend.APP_API_KEY}}`.

## 10. Deployen und prüfen

Ein Push auf `main` bzw. `develop` löst den Deploy aus. Kontrolle:

```bash
railway deployment list --service backend --environment production --json
railway logs --service backend --environment production --lines 100
```

Anschließend das Abnahmeskript gegen die erzeugten Domains laufen lassen – es ersetzt einzelne `curl`-Aufrufe durch einen einzigen geprüften Lauf (`scripts/railway-smoke.sh`, Aufruf über `make smoke`):

```bash
SK8_BACKEND_URL=https://backend-production-xxxx.up.railway.app \
SK8_DOCS_URL=https://docs-production-xxxx.up.railway.app \
SK8_SKATE_URL=https://skate-production-xxxx.up.railway.app \
SK8_NUTRITION_URL=https://nutrition-production-xxxx.up.railway.app \
SK8_HABITS_URL=https://habits-production-xxxx.up.railway.app \
SK8_API_KEY="$(railway variable list --service backend --environment production --kv | grep '^APP_API_KEY=' | cut -d= -f2-)" \
make smoke
```

Ein Deploy gilt erst als erfolgreich, wenn die Deployment-Liste `SUCCESS` zeigt **und** `make smoke` mit Rückgabewert `0` endet. Bei `FAILED`/`CRASHED` oder einem `FAIL` im Abnahmeskript zuerst „Wenn ein Deploy scheitert" unten lesen.

**Aufräumen:** Eine der Prüfungen des Skripts schreibt eine echte Zeile in `ux_event` (Filter `screen = 'smoke-test'`). Nach jedem Lauf gegen eine echte Installation:

```bash
railway connect postgres --environment production
```
```sql
\c sk8_backend
DELETE FROM ux_event WHERE screen = 'smoke-test';
```

## Was passiert, wenn eine Variable fehlt

Der wichtigste Zugewinn dieses Abschnitts: die meisten fehlenden Variablen führen **nicht** zu einem sichtbaren Absturz, sondern zu einem stillen Rückfall auf einen eingebackenen Entwicklungswert – `composer dump-env prod` bäckt die `.env`-Defaults zur Build-Zeit fest ins Image ein. Ein Konfigurationsfehler, der nicht abstürzt, ist gefährlicher als einer, der es tut: Er bleibt unbemerkt.

| Variable | Fehlt → Verhalten | Folge |
|---|---|---|
| `APP_API_KEY` (backend) | **Kein Absturz** – Rückfall auf den eingebackenen Wert `dev-key-change-me` | Die öffentliche API akzeptiert den allgemein bekannten Entwicklungsschlüssel |
| `CORS_ALLOW_ORIGIN` (backend) | **Kein Absturz** – Rückfall auf `^https?://localhost(:[0-9]+)?$` | Die installierten Apps werden vom Browser blockiert; sichtbar nur in der Browser-Konsole, nicht im Server-Log |
| `APP_SECRET` (backend) | Kein Absturz – leerer Wert | Signierte URLs und CSRF-Schutz unsicher; kein sichtbarer Fehler |
| `APP_SECRET` (docs) | Kein Absturz – Rückfall auf `dev-secret-change-me` | wie oben |
| `DATABASE_URL` | Rückfall auf `host.docker.internal:5432` – auf Railway nicht erreichbar | Entrypoint bricht nach 60 Verbindungsversuchen ab, Deploy scheitert **sichtbar** (`CRASHED`) |
| `PORT` (backend) | Entrypoint nimmt `8000` | funktioniert lokal; der Docker-Healthcheck ruft fest `http://localhost:8000/api/health`, deshalb wird `PORT` trotzdem explizit gesetzt statt auf den Default zu vertrauen |
| `PORT` (docs) | Entrypoint übernimmt `PORT` nur, wenn gesetzt, sonst Caddy-Default `8000` | funktioniert – anders als beim Backend liest bereits der Docs-Healthcheck selbst `${PORT:-8000}`; `PORT` wird trotzdem explizit gesetzt, damit Railways Port-Erkennung nichts erraten muss |
| `PORT` (Frontends) | Caddy nimmt `80` (`Caddyfile`) | funktioniert; wird trotzdem gesetzt, damit Railways Port-Erkennung nichts erraten muss |
| `SYMFONY_TRUSTED_PROXIES` | Symfony hält den Railway-Proxy für den Client | `X-Forwarded-Proto` wird ignoriert, erzeugte absolute URLs sind `http` statt `https` |
| `ANTHROPIC_API_KEY` | leer | **gewollt**: KI-Endpunkte antworten `503`, alles andere arbeitet normal (ADR-010) |

## Kosten

> Diese Tabelle nennt Kostenarten, keine festen Preise – Preise ändern sich. Vor jeder Freigabe gegen die aktuelle Railway-Preisseite (railway.com/pricing) prüfen, nie aus dem Gedächtnis übernehmen (gleiches Prinzip wie bei KI-Modellkennungen, ADR-010).

| Kostenart | Betroffene Ressourcen | Vor Freigabe prüfen |
|---|---|---|
| Postgres-Volume | `postgres` (production, ggf. development) | Volumegröße × aktueller Preis pro GB |
| Service-Laufzeit (Compute) | `backend`, `docs`, `skate`, `nutrition`, `habits` je Environment | vCPU/RAM-Nutzung × aktueller Preis; für eine Einzelnutzer-App klein |
| Egress | ausgehender Traffic aller Services | bei einer Trainings-App mit einem Nutzer vernachlässigbar |
| Domains | eine kostenlose Railway-Domain pro Service (Schritt 5) | eine eigene Domain wäre zusätzlich, hier nicht vorgesehen |

**Verbrauchsschätzung:** Grundlage ist ein Environment mit sechs kleinen, dauerhaft laufenden Services, je **1 Replica** – kein Autoscaling nötig für eine Einzelnutzer-App. `development` verdoppelt das nur, sobald es tatsächlich angelegt wird (siehe „Environments" unten).

**„Serverless"/Kaltstart bewusst nicht gewählt:** Railway bietet Serverless-Betrieb mit Kaltstart bei Inaktivität an. Für diese App bewusst nicht genutzt – ein Kaltstart mitten im Training wäre eine schlechtere Reaktionszeit als die zusätzlichen Kosten für Dauerbetrieb bei diesem kleinen Ressourcenbedarf rechtfertigen.

**Harte Grenze empfohlen:**

```bash
railway usage limit set --target workspace --soft <N> --hard <N> --json
```

`<N>` gegen die geprüften Preise und die Verbrauchsschätzung oben festlegen, nicht raten. `--soft` löst eine E-Mail-Warnung aus, `--hard` einen Stopp neuer Nutzung. Aktuellen Stand prüfen: `railway usage --json` bzw. `railway usage limit status`.

## Wenn ein Deploy scheitert

| Fall | Railway-Verhalten | Maßnahme | Befehl |
|---|---|---|---|
| Build fehlgeschlagen | Deployment bleibt `FAILED`; ein vorheriger erfolgreicher Deploy (falls vorhanden) bleibt aktiv | Build-Logs lesen, Ursache im App-Repo beheben, erneut pushen oder redeployen | `railway logs --service <s> --environment <e> --build` |
| Container startet nicht | Deployment wird `CRASHED`, Healthcheck schlägt fehl | Deploy-Logs lesen – meist eine fehlende oder falsche Variable (siehe „Was passiert, wenn eine Variable fehlt") | `railway logs --service <s> --environment <e> --deployment` |
| Datenbank nicht erreichbar | Entrypoint bricht nach 60 Verbindungsversuchen ab, Deployment `CRASHED` | `DATABASE_URL`/Referenz prüfen, Status des `postgres`-Service prüfen | `railway variable list --service <s> --environment <e> --json`, `railway status --json` |
| Migration fehlgeschlagen | backend: `--all-or-nothing` – die fehlgeschlagene Migration wird vollständig zurückgerollt, der Container bleibt trotzdem unten, weil der Entrypoint danach abbricht. docs: ohne `--all-or-nothing` – kann teilweise angewendet worden sein | Migration im jeweiligen App-Repo korrigieren, Status per SSH prüfen, erneut deployen | `railway ssh --service backend --environment production php bin/console doctrine:migrations:status` |
| Grüner, aber fachlich falscher Deploy | Kein CLI-Rollback in 5.45.5 (`railway deployment --help` kennt nur `list`, `up`, `redeploy`) | Fehlerhaften Commit im jeweiligen App-Repo zurücknehmen, neu deployen | `git revert <commit>` (im App-Repo, nicht hier) |
| Beschädigte Daten | Kein automatischer Rückweg | Aus dem letzten Backup wiederherstellen | `pg_restore -d "<DATABASE_PUBLIC_URL mit /sk8_backend>" backups/sk8_backend-<datum>.dump` |

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
| `SYMFONY_TRUSTED_PROXIES` | `REMOTE_ADDR` | `REMOTE_ADDR` |
| `DATABASE_URL` | ref: `postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_backend?serverVersion=16&charset=utf8` | identisch (zeigt auf die Development-Instanz) |
| `APP_API_KEY` | secret (`openssl rand -hex 32`) | eigenes secret |
| `CORS_ALLOW_ORIGIN` | Regex über die drei Production-Frontend-Domains | Regex über die drei Development-Frontend-Domains |
| `ANTHROPIC_API_KEY` | vom Entwickler, sobald vorhanden | leer oder eigener Key mit Kostenlimit |
| `AI_MODEL_VISION` | erst mit dem ersten KI-Feature (ADR-010) | identisch |
| `AI_MODEL_TEXT` | erst mit dem ersten KI-Feature (ADR-010) | identisch |
| `MESSENGER_TRANSPORT_DSN` | `doctrine://default?auto_setup=0` | identisch |
| `DEFAULT_URI` | ref: `https://${{RAILWAY_PUBLIC_DOMAIN}}` | identisch |

### docs

| Variable | production | development |
|---|---|---|
| `APP_ENV` | `prod` | `prod` |
| `APP_SECRET` | secret | eigenes secret |
| `PORT` | `8000` | `8000` |
| `SYMFONY_TRUSTED_PROXIES` | `REMOTE_ADDR` | `REMOTE_ADDR` |
| `DATABASE_URL` | ref: `postgresql://${{postgres.PGUSER}}:${{postgres.PGPASSWORD}}@${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/sk8_docs?serverVersion=16&charset=utf8` | identisch |
| `DEFAULT_URI` | ref: `https://${{RAILWAY_PUBLIC_DOMAIN}}` | identisch |

### skate, nutrition, habits (Build-Zeit)

| Variable | production | development |
|---|---|---|
| `VITE_API_URL` | `https://<backend-production-domain>` | `https://<backend-development-domain>` |
| `VITE_API_KEY` | ref: `${{backend.APP_API_KEY}}` | identisch (löst zum Development-Backend auf) |
| `VITE_TELEMETRY` | `on` | `on` (identisch – das Frontend prüft nur auf `off`) |
| `PORT` | `80` | `80` |

## Betrieb auf Railway

| Aufgabe | Befehl |
|---|---|
| Build-Logs | `railway logs --service backend --environment production --build --lines 200` |
| Deploy-Logs (Laufzeit) | `railway logs --service backend --environment production --deployment --lines 200` (auch ohne `--deployment`: `railway logs` zeigt ohne `--build`/`--http`/`--network`/`--dns` bereits die Deploy-Logs) |
| Deploy-Status | `railway deployment list --service backend --environment production --json` |
| Neu deployen ohne Commit | `railway redeploy --service skate --environment production -y` |
| Migrations-Status | `railway ssh --service backend --environment production php bin/console doctrine:migrations:status` |
| psql auf die Instanz | `railway connect postgres --environment production`, danach `\c sk8_backend` (die Standarddatenbank der Instanz heißt `railway`, nicht `sk8_backend`) |
| Backup | Dashboard → Postgres → Backups (Volume-Snapshots) oder `pg_dump -Fc "<DATABASE_PUBLIC_URL mit /sk8_backend>" > backups/sk8_backend-$(date +%Y%m%d).dump` |
| API-Key rotieren | siehe Ablauf unten |
| Verbrauch/Grenzen prüfen | `railway usage --json` bzw. `railway usage limit status`; Grenze setzen: `railway usage limit set --target workspace --soft <N> --hard <N> --json` |

`railway ssh` nimmt den Befehl als Positionsargument entgegen (`[COMMAND]...`) – **kein** `--`-Trenner davor.

### API-Key rotieren

Vollständiger Ablauf, inklusive des Zeitfensters, in dem alte Frontend-Bundles `401` bekommen (weil `VITE_API_KEY` zur Build-Zeit eingebacken ist, ADR-006):

1. Neuen Schlüssel setzen – ab sofort lehnt das Backend den alten Schlüssel ab:
   ```bash
   openssl rand -hex 32 | tr -d '\n' | railway variable set APP_API_KEY --stdin --service backend --environment production
   ```
2. Ab diesem Moment antworten alle drei Frontends mit ihrem **alten**, eingebackenen Schlüssel `401` – das Zeitfenster dauert, bis Schritt 3 abgeschlossen ist.
3. Frontends neu bauen, damit sie den neuen Schlüssel über die Referenz `${{backend.APP_API_KEY}}` einbacken:
   ```bash
   for service in skate nutrition habits; do
     railway redeploy --service "$service" --environment production -y
   done
   ```
4. Prüfen: `scripts/railway-smoke.sh` gegen die Production-URLs laufen lassen (`make smoke` mit den `SK8_*_URL`-Variablen aus Schritt 10). Ein `FAIL` bei `telemetry-accepted` zeigt, dass Backend und Frontends noch nicht denselben Schlüssel verwenden.

## Environments

Betrieben wird zunächst nur `production`. Ein zweites Environment (`development`, Schritt 9) lohnt sich erst bei einem konkreten Auslöser, zum Beispiel:

- gleichzeitige Feature-Entwicklung mit eigenem Testbedarf, bevor in `main` gemerged wird,
- ein Migrations-Test vor der Production-Datenbank,
- ein Regressionstest nach einem Dependency-Update, das produktiv noch nicht laufen soll.

Bis einer dieser Fälle eintritt, bleibt `development` unangelegt (ADR-005) – ein zweites Environment kostet eine zweite Postgres-Instanz und zweite Service-Laufzeiten (siehe „Kosten" oben).
