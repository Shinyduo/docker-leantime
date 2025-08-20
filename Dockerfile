# =========================
# Build stage
# =========================
FROM --platform=$TARGETPLATFORM php:8.3-fpm-alpine AS builder

# Add QEMU for cross-platform builds (useful in some CI contexts)
COPY --from=tonistiigi/binfmt:latest /usr/bin/qemu-* /usr/bin/

# Install build dependencies
RUN apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    gcc \
    g++ \
    openssl-dev \
    make \
    libxml2-dev \
    oniguruma-dev \
    openldap-dev \
    zstd-dev \
    libzip-dev \
    freetype-dev \
    libpng-dev \
    libjpeg-turbo-dev

# Cross-compilation flags applied within same RUN as extension builds if needed
ARG TARGETPLATFORM

# Install and configure PHP extensions
RUN set -ex; \
    case "${TARGETPLATFORM}" in \
      linux/arm64*) export CFLAGS='-march=armv8-a' CXXFLAGS='-march=armv8-a' ;; \
    esac; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j$(nproc) mysqli pdo_mysql bcmath mbstring exif pcntl opcache ldap zip; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    docker-php-ext-install -j$(nproc) gd; \
    rm -rf /tmp/*

# =========================
# Production stage
# =========================
FROM --platform=$TARGETPLATFORM php:8.3-fpm-alpine

# Add production dependencies (curl used by healthcheck)
RUN apk add --no-cache \
    tini \
    nginx \
    curl \
    mysql-client \
    openssl \
    supervisor \
    freetype \
    libpng \
    zstd-libs \
    libjpeg-turbo \
    libzip \
    openldap \
    icu-libs

# Copy built extensions and PHP configs from builder
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Non-root user setup (configurable UID/GID)
ARG PUID=1000
ARG PGID=1000

# Working dir for app
WORKDIR /var/www/html

# Create users, groups, and required directories first
RUN set -ex; \
    deluser www-data || true; \
    addgroup -g ${PGID} www-data; \
    adduser -u ${PUID} -G www-data -h /home/www-data -s /bin/sh -D www-data; \
    mkdir -p /var/www/html/userfiles \
            /var/www/html/public/userfiles \
            /var/www/html/bootstrap/cache \
            /var/www/html/storage/logs \
            /var/www/html/storage/framework/cache \
            /var/www/html/storage/framework/sessions \
            /var/www/html/storage/framework/views \
            /var/www/html/app/Plugins \
            /run /var/log/nginx /var/lib/nginx

# Install Leantime
# Accepts LEAN_VERSION as "2.5.x" or "v2.5.x"
ARG LEAN_VERSION
RUN set -ex; \
    test -n "$LEAN_VERSION" || { echo "LEAN_VERSION is empty"; exit 1; }; \
    VERSION_NO_V="${LEAN_VERSION#v}"; \
    URL="https://github.com/Leantime/leantime/releases/download/v${VERSION_NO_V}/Leantime-v${VERSION_NO_V}.tar.gz"; \
    echo "Downloading $URL"; \
    curl -fSsvL --retry 3 --retry-delay 3 "$URL" -o leantime.tar.gz; \
    tar xzf leantime.tar.gz --strip-components 1; \
    rm leantime.tar.gz

# Permissions
RUN set -ex; \
    chown -R www-data:www-data /var/www/html /run /var/log/nginx /var/lib/nginx; \
    chmod 775 /var/www/html/userfiles \
               /var/www/html/public/userfiles \
               /var/www/html/bootstrap/cache \
               /var/www/html/storage/logs \
               /var/www/html/storage/framework/cache \
               /var/www/html/storage/framework/sessions \
               /var/www/html/storage/framework/views \
               /var/www/html/app/Plugins

# Copy configuration files (ensure these exist in your build context)
# - custom.ini: PHP overrides (upload limits, memory, etc.)
# - nginx.conf: Make sure it listens on 8080 if you keep EXPOSE 8080
# - php-fpm.conf: Pool config (socket or TCP matching nginx upstream)
# - supervisord.conf: Supervises nginx and php-fpm or your chosen process model
COPY config/custom.ini /usr/local/etc/php/conf.d/
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Startup script to launch supervisord (or services) under tini
COPY --chmod=0755 start.sh /start.sh

# Switch to non-root user
USER www-data

# Healthcheck (ensure nginx listens on 8080 or change to 80)
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -fsS http://localhost:8080 || exit 1

EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/start.sh"]
