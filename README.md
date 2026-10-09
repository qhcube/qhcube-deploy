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
~/qhcube-back  -> releases/<ver>/qhcube-back       # symlink (relativo) a la versión activa
~/qhcube-front -> releases/<ver>/qhcube-front      # symlink (relativo) a la versión activa
~/releases/<ver>/
    qhcube-back/qhcube-back-<ver>.jar
    qhcube-front/                                  # dist del frontend desempaquetado
    qhcube-front-<ver>.tar.gz
    SHA256SUMS
~/mysql_prod_data/        # datos de MySQL
~/backups/<fecha>/        # volcados de la BD
```

Docker resuelve los symlinks **al crear el contenedor**, no al reiniciarlo. Por eso, después de cambiar un symlink
hay que recrear los contenedores con `docker compose up -d --force-recreate`.

## Publicar una versión nueva

Se supone que la versión ya está etiquetada (`vX.Y.Z`) en `master` de `qhcube-front` y `qhcube-back`.
En los ejemplos, `VER=X.Y.Z`.

### 1. Construir los artefactos (en local)

```bash
VER=X.Y.Z
DEST=~/Proyectos/04\ -\ QHCube/releases/$VER
mkdir -p "$DEST"/qhcube-back

# Backend
cd qhcube-back && git checkout v$VER
./mvnw clean package
cp target/qhcube-back-$VER.jar "$DEST"/qhcube-back/

# Frontend (la URL del backend se toma de src/.env.production)
cd ../qhcube && git checkout v$VER
npm ci
npm run build
tar czf "$DEST"/qhcube-front-$VER.tar.gz -C dist .

# Sumas de comprobación (con la misma estructura que tendrá en el servidor)
cd "$DEST" && sha256sum qhcube-back/qhcube-back-$VER.jar qhcube-front-$VER.tar.gz > SHA256SUMS
```

La carpeta local de la versión queda así, con la misma estructura que en el servidor:

```
releases/<ver>/
    qhcube-back/qhcube-back-<ver>.jar
    qhcube-front-<ver>.tar.gz
    SHA256SUMS
```

### 2. Subirlos al servidor

```bash
scp -r "$DEST" qhcube_usr@qhcube.etsisi.upm.es:releases/
```

### 3. Preparar la versión (en el servidor)

```bash
VER=X.Y.Z
cd ~/releases/$VER
sha256sum -c SHA256SUMS                  # ambos deben dar OK
mkdir qhcube-front
tar xzf qhcube-front-$VER.tar.gz -C qhcube-front
```

### 4. Copia de seguridad de la BD

Antes de activar la versión nueva, siempre: ver [Backups](#backups).

### 5. Activar la versión

```bash
cd ~
ln -sfn releases/$VER/qhcube-back  qhcube-back
ln -sfn releases/$VER/qhcube-front qhcube-front
cd ~/qhcube-deploy
docker compose up -d --force-recreate
docker compose logs -f spring-prod       # esperar a "Started ..." y salir con Ctrl+C
```

(`-n` hace que `ln` sustituya el symlink en vez de crear uno nuevo dentro del directorio al que apunta.)

Comprobar en el navegador que la web carga y que se puede iniciar sesión y jugar.

> Hibernate está con `ddl-auto=update`: crea tablas y columnas nuevas, pero **nunca modifica columnas existentes**.
> Si una versión cambia el tipo o tamaño de una columna, hay que hacer el `ALTER TABLE` a mano
> (ej.: `movs_list` se pasó a `LONGTEXT` a mano en la 0.1.1).

## Volver a una versión anterior (rollback)

Las versiones anteriores siguen en `~/releases/`. Basta con apuntar los symlinks a la anterior y recrear:

```bash
PREV=X.Y.Z
cd ~
ln -sfn releases/$PREV/qhcube-back  qhcube-back
ln -sfn releases/$PREV/qhcube-front qhcube-front
cd ~/qhcube-deploy
docker compose up -d --force-recreate
```

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

```bash
D=~/backups/$(date +%F)
mkdir -p $D
docker exec mysql-prod sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines qhcube_db' \
    > $D/qhcube_db.sql
```

La contraseña de root no aparece en la línea de órdenes: `$MYSQL_ROOT_PASSWORD` se expande **dentro** del contenedor
(por eso va entre comillas simples).

Se guardan tres copias: en el servidor, en el NAS (otro edificio) y en un disco USB desconectado.

### Restauración

```bash
docker exec -i mysql-prod sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" qhcube_db' \
    < ~/backups/<fecha>/qhcube_db.sql
```

## Acceso a la base de datos

Desde el equipo local, abrir un túnel SSH:

```bash
ssh -L 8081:127.0.0.1:8081 -L 3306:127.0.0.1:3306 qhcube_usr@qhcube.etsisi.upm.es
```

- Adminer: <http://localhost:8081> (servidor `db-prod`).
- Cliente MySQL / IDE: `localhost:3306`.

## Instalación desde cero

1. Instalar Docker y el plugin Compose en el servidor.
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
4. Preparar una versión en `~/releases/<ver>/` y crear los symlinks (pasos 2, 3 y 5 de
   [Publicar una versión nueva](#publicar-una-versión-nueva)).
5. `docker compose up -d`.
6. La primera vez, MySQL solo crea el usuario `root`: la base de datos y el usuario de la aplicación hay que crearlos
   a mano (los valores de `MYSQL_DATABASE`, `DB_USER` y `DB_PASSWORD` del `.env`):

   ```sql
   CREATE DATABASE qhcube_db;
   CREATE USER '<DB_USER>'@'%' IDENTIFIED BY '<DB_PASSWORD>';
   GRANT ALL PRIVILEGES ON qhcube_db.* TO '<DB_USER>'@'%';
   ```

   Después, restaurar el último backup si lo hay y reiniciar Spring: `docker compose restart spring-prod`.
