-- This file contains functions that aid in inserting data into a hypertable.

-- Get a comma-separated list of columns in a hypertable.
CREATE OR REPLACE FUNCTION _iobeamdb_internal.get_column_list(
    hypertable_name NAME
)
    RETURNS TEXT LANGUAGE SQL STABLE AS
$BODY$
SELECT array_to_string(get_quoted_column_names(hypertable_name), ', ')
$BODY$;

-- Gets the partition ID of a given epoch and data row.
--
-- epoch - The epoch whose partition ID we want
-- copy_record - Record/row from a table
-- copy_table_name - Name of the relation to cast the record to.
CREATE OR REPLACE FUNCTION _iobeamdb_internal.get_partition_for_epoch_row(
    epoch           _iobeamdb_catalog.partition_epoch,
    copy_record     anyelement,
    copy_table_name TEXT
)
    RETURNS _iobeamdb_catalog.partition LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    partition_row _iobeamdb_catalog.partition;
BEGIN
    EXECUTE format(
        $$
            SELECT  p.*
            FROM _iobeamdb_catalog.partition p
            WHERE p.epoch_id = %L AND
            %s((SELECT row.%I FROM (SELECT (%L::%s).*) as row), %L)
            BETWEEN p.keyspace_start AND p.keyspace_end
        $$,
            epoch.id, epoch.partitioning_func,
            epoch.partitioning_column,
            copy_record, copy_table_name, epoch.partitioning_mod)
    INTO STRICT partition_row;

    RETURN partition_row;
END
$BODY$;

-- Gets the value of the time column from a given row.
--
-- column_name - Name of time column to fetch
-- column_type - Type of the time record
-- copy_record - Record/row from a table
-- copy_table_name - Name of the relation to cast the record to
CREATE OR REPLACE FUNCTION _iobeamdb_internal.get_time_column_from_record(
    column_name      NAME,
    column_type      REGTYPE,
    copy_record     anyelement,
    copy_table_name TEXT
)
    RETURNS bigint LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    t bigint;
BEGIN
    EXECUTE format(
        $$
            SELECT %s FROM (SELECT (%L::%s).*) as row LIMIT 1
        $$, _iobeamdb_internal.extract_time_sql(format('row.%I', column_name), column_type), copy_record, copy_table_name)
    INTO STRICT t;

    RETURN t;
END
$BODY$;

-- Inserts rows from a (temporary) table into correct hypertable child tables.
--
-- In typical use case, the copy_table_oid is the OID of a hypertable's main
-- table. This allows users to use normal SQL INSERT calls on the main table,
-- and a trigger that executes after the statement will call this function to
-- place the data appropriately.
--
-- hypertable_name - Name of the hypertable the data belongs to
-- copy_table_oid -- OID of the table to fetch rows from
CREATE OR REPLACE FUNCTION insert_data(
    hypertable_name NAME,
    copy_table_oid  REGCLASS
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    point_record_query_sql      TEXT;
    point_record                RECORD;
    chunk_row                   _iobeamdb_catalog.chunk;
    crn_record                  RECORD;
    distinct_table_oid          REGCLASS;
    distinct_column             TEXT;
    distinct_clauses            TEXT;
    distinct_clause_idx         INT;
BEGIN
    --This guard protects against calling insert_data() twice in the same transaction,
    --which might otherwise cause a deadlock in case the second insert_data() involves a chunk
    --that was inserted into in the first call to insert_data().
    --This is a temporary safe guard that should ideally be removed once chunk management
    --has been refactored and improved to avoid such deadlocks.
    --NOTE: In its current form, this safe guard unfortunately prohibits transactions
    --involving INSERTs on two different hypertables.
    IF current_setting('io.insert_data_guard', true) = 'on' THEN
        RAISE EXCEPTION 'insert_data() can only be called once per transaction';
    END IF;

    PERFORM set_config('io.insert_data_guard', 'on', true);

    point_record_query_sql := format(
        $$
            SELECT _iobeamdb_internal.get_time_column_from_record(h.time_column_name, h.time_column_type, ct, '%1$s') AS time,
                   h.time_column_name, h.time_column_type,
                   p.id AS partition_id, p.keyspace_start, p.keyspace_end,
                   pe.partitioning_func, pe.partitioning_column, pe.partitioning_mod
            FROM ONLY %1$s ct
            LEFT JOIN _iobeamdb_catalog.hypertable h ON (h.NAME = %2$L)
            LEFT JOIN _iobeamdb_catalog.partition_epoch pe ON (
              pe.hypertable_name = %2$L AND
              (pe.start_time <= (SELECT _iobeamdb_internal.get_time_column_from_record(h.time_column_name, h.time_column_type, ct, '%1$s'))::bigint
                OR pe.start_time IS NULL) AND
              (pe.end_time   >= (SELECT _iobeamdb_internal.get_time_column_from_record(h.time_column_name, h.time_column_type, ct, '%1$s'))::bigint
                OR pe.end_time IS NULL)
            )
            LEFT JOIN _iobeamdb_internal.get_partition_for_epoch_row(pe, ct, '%1$s') AS p ON(true)
            LIMIT 1
        $$, copy_table_oid, hypertable_name);

    EXECUTE point_record_query_sql
    INTO STRICT point_record;

    IF point_record.time IS NOT NULL AND point_record.partition_id IS NULL THEN
        RAISE EXCEPTION 'Should never happen: could not find partition for insert'
        USING ERRCODE = 'IO501';
    END IF;

    WHILE point_record.time IS NOT NULL LOOP
        --Get the chunk we should insert into
        chunk_row := get_or_create_chunk(point_record.partition_id, point_record.time);

        --Check if the chunk should be closed (must be done without lock on chunk).
        PERFORM _iobeamdb_internal.close_chunk_if_needed(chunk_row);

        --Get a chunk with lock
        chunk_row := get_or_create_chunk(point_record.partition_id, point_record.time, TRUE);

        --Do insert on all chunk replicas
        FOR crn_record IN
        SELECT
            crn.database_name,
            crn.schema_name,
            crn.table_name,
            pr.hypertable_name,
            pr.replica_id
        FROM _iobeamdb_catalog.chunk_replica_node crn
        INNER JOIN _iobeamdb_catalog.partition_replica pr ON (pr.id = crn.partition_replica_id)
        WHERE (crn.chunk_id = chunk_row.id)
        LOOP
            distinct_clauses := '';
            distinct_clause_idx := 0;

            SELECT *
            INTO distinct_table_oid
            FROM get_distinct_table_oid(hypertable_name, crn_record.replica_id, crn_record.database_name);

            FOR distinct_column IN
            SELECT c.name
            FROM _iobeamdb_catalog.hypertable_column c
            WHERE c.is_distinct = TRUE AND c.hypertable_name = insert_data.hypertable_name
            ORDER BY c.name
            LOOP
                distinct_clauses := distinct_clauses || ',' || format(
                    $$
                    insert_distinct_%3$s AS (
                      INSERT INTO  %1$s as distinct_table
                      SELECT DISTINCT %2$L, selected.%2$I as value
                      FROM selected
                      ORDER BY value
                      ON CONFLICT DO NOTHING
                    )
                    $$, distinct_table_oid, distinct_column, distinct_clause_idx);
                    distinct_clause_idx := distinct_clause_idx + 1;
            END LOOP;

            PERFORM set_config('io.ignore_delete_in_trigger', 'true', true);
            EXECUTE format(
                $$
                WITH selected AS
                (
                    DELETE FROM ONLY %2$s
                    WHERE (%7$I >= %3$s OR %3$s IS NULL) AND (%7$I <= %4$s OR %4$s IS NULL) AND
                          (%8$s(%9$I, %10$L) BETWEEN %11$L AND %12$L)
                    RETURNING *
                )%5$s
                INSERT INTO %1$s (%6$s) SELECT %6$s FROM selected;
                $$,
                    format('%I.%I', crn_record.schema_name, crn_record.table_name) :: REGCLASS,
                    copy_table_oid,
                    _iobeamdb_internal.time_literal_sql(chunk_row.start_time, point_record.time_column_type),
                    _iobeamdb_internal.time_literal_sql(chunk_row.end_time, point_record.time_column_type),
                    distinct_clauses,
                    _iobeamdb_internal.get_column_list(hypertable_name),
                    point_record.time_column_name,
                    point_record.partitioning_func,
                    point_record.partitioning_column,
                    point_record.partitioning_mod,
                    point_record.keyspace_start,
                    point_record.keyspace_end
                );
        END LOOP;

        EXECUTE point_record_query_sql
        INTO point_record;

        IF point_record.time IS NOT NULL AND point_record.partition_id IS NULL THEN
            RAISE EXCEPTION 'Should never happen: could not find partition for insert'
            USING ERRCODE = 'IO501';
        END IF;
    END LOOP;
END
$BODY$;
