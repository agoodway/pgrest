# TEST HARNESS ONLY. Postgres 16 with the pg-safeupdate extension, the library Supabase
# loads so that UPDATE and DELETE without a WHERE clause fail with SQLSTATE 21000.
FROM postgres:16

# Newest tag at the time of writing (1.7), pinned by commit so the build is reproducible.
ARG PG_SAFEUPDATE_REF=37dbc9c4acf5e2504adf2b218e9c6b41751022f3

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git postgresql-server-dev-16 \
    && git clone https://github.com/eradman/pg-safeupdate.git /tmp/pg-safeupdate \
    && git -C /tmp/pg-safeupdate checkout "${PG_SAFEUPDATE_REF}" \
    && make -C /tmp/pg-safeupdate \
    && make -C /tmp/pg-safeupdate install \
    && apt-get purge -y --auto-remove build-essential git postgresql-server-dev-16 \
    && rm -rf /tmp/pg-safeupdate /var/lib/apt/lists/*
