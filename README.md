# qhcube-deploy

Configuración de despliegue de QHCube en producción (`qhcube.etsisi.upm.es`) con Docker Compose y Caddy.

Repositorios relacionados:

- `qhcube-front`: frontend (Vue + Vite).
- `qhcube-back`: backend (Spring Boot).

## Arquitectura

| Contenedor     | Imagen                         | Función                                                                                   | Puertos                 |
|----------------|--------------------------------|-------------------------------------------------------------------------------------------|-------------------------|
| `caddy-prod`   | `caddy:2.8`                    | HTTPS (Let's Encrypt automático). `/api/*` y `/free/*` → Spring; el resto → frontend estático | 80, 443                 |
| `spring-prod`  | `eclipse-temurin:17-jre-focal` | Ejecuta el jar del backend (perfil `prod`, puerto 9000 interno)                            | —                       |
| `mysql-prod`   | `mysql:8.0.33`                 | Base de datos `qhcube_db`                                                                  | `127.0.0.1:3306`        |
| `adminer-prod` | `adminer`                      | Administración web de la BD                                                                | `127.0.0.1:8081`        |

MySQL y Adminer solo escuchan en `127.0.0.1`: se accede a ellos por túnel SSH (ver más abajo).

## Estructura en el servidor

Usuario `qhcube_usr`:

```
~/qhcube-deploy/          # este repo + .env (no versionado)
~/.config/qhcube/github-token                      # token de solo lectura para descargar las releases (chmod 600)
~/qhcube-back  -> releases/<ver>/qhcube-back       # symlink (relativo) a la versión activa
~/qhcube-front -> releases/<ver>/qhcube-front      # symlink (relativo) a la versión activa
~/releases/<ver>/
    descargas/back/                                # ficheros descargados de la release (jar + SHA256SUMS)
    descargas/front/                               # ídem (tar.gz + SHA256SUMS)
    qhcube-back/qhcube-back-<ver>.jar
    qhcube-front/                                  # dist del frontend desempaquetado
~/mysql_prod_data/        # datos de MySQL
~/backups/<fecha>/        # volcados de la BD
```

Docker resuelve los symlinks **al crear el contenedor**, no al reiniciarlo. Por eso, después de cambiar un symlink
hay que recrear los contenedores con `docker compose up -d --force-recreate`.

## Publicar una versión nueva

La compilación y la publicación las hace GitHub Actions; el despliegue, un script en el servidor que descarga
de las GitHub Releases.

### 1. Preparar la versión (en local)

En `qhcube-back` y/o `qhcube-front` (cada repo solo cambia de versión si publica cambios):

1. Subir la versión en `dev`: `pom.xml` en el back; `npm version X.Y.Z --no-git-tag-version` en el front.
2. PR de `dev` a `main` con **Create a merge commit**.
3. Crear y subir el tag en `main`:

   ```bash
   git checkout main && git pull
   git tag -a vX.Y.Z -m "QHCube backend X.Y.Z"      # o "QHCube frontend X.Y.Z"
   git push origin vX.Y.Z
   ```

### 2. Publicar las releases (en GitHub)

Al subir el tag, el workflow **Publicar release** de cada repo comprueba que la versión del tag coincide con la del
proyecto, compila desde el tag (con los tests, en el back) y crea la release como **borrador** con sus ficheros
(`qhcube-back-X.Y.Z.jar` o `qhcube-front-X.Y.Z.tar.gz`, y `SHA256SUMS`).

En *Releases*, revisar el borrador, añadir una introducción a las notas y **publicarlo**. El script de despliegue
solo puede descargar releases publicadas.

### 3. Desplegar (en el servidor)

```bash
cd ~/qhcube-deploy && git pull          # para tener la última versión del script
./scripts/desplegar.sh X.Y.Z            # back y front
./scripts/desplegar.sh X.Y.Z --solo back
```

El script:

1. descarga los ficheros de las releases `vX.Y.Z` y comprueba sus sumas;
2. coloca el jar y descomprime el frontend en `~/releases/X.Y.Z/`;
3. hace una copia de seguridad de la base de datos en `~/backups/<fecha>/`;
4. muestra la versión activa y la nueva y **pide confirmación** (escribir `si`);
5. cambia los symlinks y recrea los contenedores;
6. verifica que el backend (`/free/version-back`) y el frontend sirven la versión nueva.

Si algo falla, se detiene; si falla la verificación, muestra los comandos para volver a la versión anterior.

Para comprobar una descarga sin tocar nada: `RELEASES=/tmp/prueba ./scripts/desplegar.sh X.Y.Z --solo-descarga`.

El token de descarga (`~/.config/qhcube/github-token`) es un *fine-grained token* de la organización con
**Contents: Read-only** sobre `qhcube-back` y `qhcube-front`. Caduca: cuando lo haga, generar otro igual y
sustituir el fichero (`chmod 600`).

> Hibernate está con `ddl-auto=update`: crea tablas y columnas nuevas, pero **nunca modifica columnas existentes**.
> Si una versión cambia el tipo o tamaño de una columna, hay que hacer el `ALTER TABLE` a mano
> (ej.: `movs_list` se pasó a `LONGTEXT` a mano en la 0.1.1).

## Volver a una versión anterior (rollback)

Las versiones anteriores siguen en `~/releases/`. Si la versión a la que se quiere volver tiene GitHub Releases
(0.2.0 en adelante), basta con desplegarla de nuevo:

```bash
./scripts/desplegar.sh X.Y.Z
```

A mano (también para versiones sin releases en GitHub), apuntar los symlinks a la anterior y recrear:

```bash
PREV=X.Y.Z
cd ~
ln -sfn releases/$PREV/qhcube-back  qhcube-back
ln -sfn releases/$PREV/qhcube-front qhcube-front
cd ~/qhcube-deploy
docker compose up -d --force-recreate
```

(`-n` hace que `ln` sustituya el symlink en vez de crear uno nuevo dentro del directorio al que apunta.)

Si la versión nueva había cambiado el esquema de la BD de forma incompatible, restaurar además la copia de
seguridad hecha antes del despliegue (ver abajo).

## Cambiar la configuración

`~/qhcube-deploy` en el servidor es un clon de este repo. Accede a GitHub con una *deploy key* de solo lectura, que
está en `~/.ssh/id_ed25519`. Los cambios se hacen siempre en local y el servidor solo los descarga: **nunca se editan
los ficheros directamente en el servidor**.

1. En local: editar, hacer commit y `git push`.
2. En el servidor:

   ```bash
   cd ~/qhcube-deploy
   git pull
   ```

3. Aplicar los cambios:

   - Si ha cambiado `compose.yml`:

     ```bash
     docker compose up -d
     ```

     Compose solo recrea los contenedores cuya configuración ha cambiado.

   - Si ha cambiado el `Caddyfile`:

     ```bash
     docker compose up -d --force-recreate caddy
     ```

     Hay que recrear el contenedor porque `git pull` sustituye el fichero por uno nuevo en lugar de modificarlo, y el
     contenedor seguiría viendo el antiguo.

   - Si ha cambiado `.env`: este fichero no está en git, así que se edita a mano en el servidor y después se ejecuta
     `docker compose up -d --force-recreate`.

## Backups

### Volcado

El script de despliegue hace un volcado antes de cada despliegue (`~/backups/<fecha>/qhcube_db-<hora>.sql`).
A mano:

```bash
D=~/backups/$(date +%F)
mkdir -p $D
docker exec mysql-prod sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines qhcube_db' \
    > $D/qhcube_db-$(date +%H%M%S).sql
```

La contraseña de root no aparece en la línea de órdenes: `$MYSQL_ROOT_PASSWORD` se expande **dentro** del contenedor
(por eso va entre comillas simples).

Se guardan tres copias: en el servidor, en el NAS (otro edificio) y en un disco USB desconectado.

### Restauración

```bash
docker exec -i mysql-prod sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" qhcube_db' \
    < ~/backups/<fecha>/<fichero>.sql
```

## Acceso a la base de datos

Desde el equipo local, abrir un túnel SSH:

```bash
ssh -L 8081:127.0.0.1:8081 -L 3306:127.0.0.1:3306 qhcube_usr@qhcube.etsisi.upm.es
```

- Adminer: <http://localhost:8081> (servidor `db-prod`).
- Cliente MySQL / IDE: `localhost:3306`.

## Instalación desde cero

1. Instalar Docker y el plugin Compose en el servidor, además de `curl` y `jq` (los usa el script de despliegue).
2. Crear la deploy key y clonar el repo:

   ```bash
   ssh-keygen -t ed25519 -N "" -C "qhcube_usr@qhcube deploy key"
   cat ~/.ssh/id_ed25519.pub
   ```

   Añadir la clave pública en GitHub (**qhcube-deploy → Settings → Deploy keys**, sin permiso de escritura) y
   después:

   ```bash
   git clone git@github.com:qhcube/qhcube-deploy.git ~/qhcube-deploy
   ```

3. `cp .env.example .env` y rellenar los valores (están en KeePass). `chmod 600 .env`.
4. Guardar el token de descarga (ver [Desplegar](#3-desplegar-en-el-servidor)):

   ```bash
   mkdir -p ~/.config/qhcube && chmod 700 ~/.config/qhcube
   read -s TOKEN && printf '%s' "$TOKEN" > ~/.config/qhcube/github-token && unset TOKEN
   chmod 600 ~/.config/qhcube/github-token
   ```

5. `docker compose up -d` para arrancar MySQL.
6. La primera vez, MySQL solo crea el usuario `root`: la base de datos y el usuario de la aplicación hay que crearlos
   a mano (los valores de `MYSQL_DATABASE`, `DB_USER` y `DB_PASSWORD` del `.env`):

   ```sql
   CREATE DATABASE qhcube_db;
   CREATE USER '<DB_USER>'@'%' IDENTIFIED BY '<DB_PASSWORD>';
   GRANT ALL PRIVILEGES ON qhcube_db.* TO '<DB_USER>'@'%';
   ```

   Después, restaurar el último backup si lo hay.
7. Desplegar la última versión: `./scripts/desplegar.sh X.Y.Z`.
