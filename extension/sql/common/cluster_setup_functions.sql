CREATE SCHEMA IF NOT EXISTS _iobeamdb_internal;
CREATE SCHEMA IF NOT EXISTS _iobeamdb_meta;
CREATE SCHEMA IF NOT EXISTS _iobeamdb_meta_api;
CREATE SCHEMA IF NOT EXISTS _iobeamdb_data_api;

CREATE OR REPLACE FUNCTION _iobeamdb_internal.create_user_mapping(
    cluster_user_row _iobeamdb_catalog.cluster_user,
    server_name      NAME
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
BEGIN

    EXECUTE format(
        $$
            CREATE USER MAPPING FOR %1$I SERVER %2$I OPTIONS (user '%1$s', password '%3$s')
        $$,
        cluster_user_row.username, server_name, cluster_user_row.password);
END
$BODY$;

CREATE OR REPLACE FUNCTION _iobeamdb_internal.create_server(
    server_name   NAME,
    hostname      NAME,
    database_name NAME
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
BEGIN
    EXECUTE format(
        $$
            CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS(host '%s', dbname '%s') ;
        $$,
        server_name, hostname, database_name);
END
$BODY$;
