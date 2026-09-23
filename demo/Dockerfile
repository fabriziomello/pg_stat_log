FROM postgres:18

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-18-stat-log \
    && rm -rf /var/lib/apt/lists/*

COPY initdb/ /docker-entrypoint-initdb.d/
COPY workload/loop.sh workload/healthy.sql /demo/
RUN chmod +x /demo/loop.sh
