## Schema Cache Bug

This app reproduces a bug with the schema cache when used with puma and

```
on_worker_boot do
  ActiveRecord::Base.establish_connection
end
```

## Prepare

Generate the database, migrate it, and dump the schema cache

```
RAILS_ENV=production rake db:create db:migrate db:schema:cache:dump
```

## Detect

There's several ways to detect the issue, either directly through pg stat statements:


```
$ rails dbconsole

-- clear
SELECT pg_stat_statements_reset();


-- get output
SELECT interval '1 millisecond' * total_time AS total_exec_time,
to_char((total_time/sum(total_time) OVER()) * 100, 'FM90D0') || '%'  AS prop_exec_time,
to_char(calls, 'FM999G999G999G990') AS ncalls,
interval '1 millisecond' * (blk_read_time + blk_write_time) AS sync_io_time,
query AS query
FROM pg_stat_statements WHERE userid = (SELECT usesysid FROM pg_user WHERE usename = current_user LIMIT 1)
ORDER BY total_time DESC
LIMIT 100;
```

Or, you can `bundle open activerecord` and add debugging output to `schema_statements.rb` that will fire when primary keys are called:

```
        def primary_keys(table_name) # :nodoc:
          puts "==========================="
          puts table_name
          puts caller
          query_values(<<-SQL.strip_heredoc, "SCHEMA")
            SELECT a.attname
              FROM (
                     SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
                       FROM pg_index
                      WHERE indrelid = #{quote(quote_table_name(table_name))}::regclass
                        AND indisprimary
                   ) i
              JOIN pg_attribute a
                ON a.attrelid = i.indrelid
               AND a.attnum = i.indkey[i.idx]
             ORDER BY i.idx
          SQL
        end
```

You can always `gem pristine activerecord` to get it back to normal

## Trigger the code

The issue only triggers from the web so you'll have to boot a webserver

```
$ RAILS_ENV=production SECRET_KEY_BASE=foo RAILS_LOG_TO_STDOUT=1 rails s
```

Then visit http://localhost:3000/users.

## What you should see

If you monkeypatched active record you'll see that it hits the database:

```
===========================
users
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/connection_adapters/abstract/schema_statements.rb:146:in `primary_key'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/connection_adapters/schema_cache.rb:46:in `primary_keys'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/attribute_methods/primary_key.rb:100:in `get_primary_key'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/attribute_methods/primary_key.rb:87:in `reset_primary_key'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/attribute_methods/primary_key.rb:75:in `primary_key'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/model_schema.rb:329:in `attributes_builder'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/persistence.rb:70:in `instantiate'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/querying.rb:53:in `block (2 levels) in find_by_sql'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/result.rb:57:in `block in each'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/result.rb:57:in `each'
/Users/rschneeman/.gem/ruby/2.6.2/gems/activerecord-5.2.2.1/lib/active_record/result.rb:57:in `each'
```


If you chose to use the pg stat statements then you can see this:


```
schema_cache_production=# SELECT interval '1 millisecond' * total_time AS total_exec_time,
to_char((total_time/sum(total_time) OVER()) * 100, 'FM90D0') || '%'  AS prop_exec_time,
to_char(calls, 'FM999G999G999G990') AS ncalls,
interval '1 millisecond' * (blk_read_time + blk_write_time) AS sync_io_time,
query AS query
FROM pg_stat_statements WHERE userid = (SELECT usesysid FROM pg_user WHERE usename = current_user LIMIT 1)
ORDER BY total_time DESC
LIMIT 100;
 total_exec_time | prop_exec_time | ncalls | sync_io_time |                                                                                                            query
-----------------+----------------+--------+--------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 00:00:00.006206 | 43.8%          | 1      | 00:00:00     | SELECT a.attname                                                                                                                                                                                                            +
                 |                |        |              |   FROM (                                                                                                                                                                                                                    +
                 |                |        |              |          SELECT indrelid, indkey, generate_subscripts(indkey, $1) idx                                                                                                                                                       +
                 |                |        |              |            FROM pg_index                                                                                                                                                                                                    +
                 |                |        |              |           WHERE indrelid = $2::regclass                                                                                                                                                                                     +
                 |                |        |              |             AND indisprimary                                                                                                                                                                                                +
                 |                |        |              |        ) i                                                                                                                                                                                                                  +
                 |                |        |              |   JOIN pg_attribute a                                                                                                                                                                                                       +
                 |                |        |              |     ON a.attrelid = i.indrelid                                                                                                                                                                                              +
                 |                |        |              |    AND a.attnum = i.indkey[i.idx]                                                                                                                                                                                           +
                 |                |        |              |  ORDER BY i.idx
```


## Expected

The schema cache should prevent our database from being queried for primary key information.

## Actual

The database queries postgresql for primary key data (and others below).

## Extra

It's also worth mentioning that there are some other queries in there that look like they shouldn't be totally needed if we're using a schema cache:


```
 00:00:00.003818 | 27.0%          | 2      | 00:00:00     | SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype, t.typtype, t.typbasetype                                                                                                                          +
                 |                |        |              |               FROM pg_type as t                                                                                                                                                                                             +
                 |                |        |              |               LEFT JOIN pg_range as r ON oid = rngtypid                                                                                                                                                                     +
                 |                |        |              |               WHERE                                                                                                                                                                                                         +
                 |                |        |              |                 t.typname IN ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27, $28, $29, $30, $31, $32, $33, $34, $35, $36, $37, $38, $39, $40)+
                 |                |        |              |                 OR t.typtype IN ($41, $42, $43)                                                                                                                                                                             +
                 |                |        |              |                 OR t.typinput = $44::regprocedure                                                                                                                                                                           +
                 |                |        |              |                 OR t.typelem != $45
 00:00:00.001638 | 11.6%          | 2      | 00:00:00     | SELECT a.attname, format_type(a.atttypid, a.atttypmod),                                                                                                                                                                     +
                 |                |        |              |                      pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,                                                                                                                                +
                 |                |        |              |                      c.collname, col_description(a.attrelid, a.attnum) AS comment                                                                                                                                           +
                 |                |        |              |                 FROM pg_attribute a                                                                                                                                                                                         +
                 |                |        |              |                 LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum                                                                                                                                     +
                 |                |        |              |                 LEFT JOIN pg_type t ON a.atttypid = t.oid                                                                                                                                                                   +
                 |                |        |              |                 LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation                                                                                                                     +
                 |                |        |              |                WHERE a.attrelid = $1::regclass                                                                                                                                                                              +
                 |                |        |              |                  AND a.attnum > $2 AND NOT a.attisdropped                                                                                                                                                                   +
                 |                |        |              |                ORDER BY a.attnum
```