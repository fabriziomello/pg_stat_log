FROM postgres:18 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        postgresql-server-dev-$PG_MAJOR \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile generate-errcode-names.pl pg_stat_log.c pg_stat_log.control \
    pg_stat_log--*.sql ./
RUN make PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config DESTDIR=/out install

FROM postgres:18

COPY --from=build /out/ /
COPY demo/initdb/ /docker-entrypoint-initdb.d/
COPY demo/workload/ /demo/
RUN chmod +x /demo/loop.sh
