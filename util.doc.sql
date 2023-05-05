\if :{?util_doc_sql}
\else
\set util_doc_sql true

\if :test
\if :local
    drop schema if exists util cascade;
\endif
\endif
create schema if not exists util;

create or replace function util.doc_ (
    cls_ text
)
    returns text
    language plpgsql
as $$
declare
    a text;
begin
    a = case
    -- regproc
    when position('(' in cls_) > 1 then
        case
        when to_regprocedure(cls_) is not null
        then util.doc(obj_description(cls_::regprocedure, 'pg_proc'))
        else null
        end

    -- schema.entity
    when cardinality(parse_ident(cls_)) < 3 then
        coalesce(
            case
            when to_regclass(cls_) is not null
            then util.doc(obj_description(cls_::regclass, 'pg_class'))
            else null
            end,

            case
            when to_regtype(cls_) is not null
            then util.doc(obj_description(cls_::regtype, 'pg_type'))
            else null
            end,

            case
            when to_regproc(cls_) is not null
            then util.doc(obj_description(cls_::regproc, 'pg_proc'))
            else null
            end
        )

    -- schema.table.column
    when cardinality(parse_ident(cls_)) = 3 then
        (
            with
            parsed as (
                select parse_ident(cls_) ids
            )
            select case
            when cardinality(parsed.ids)=3
            then (
                    select coalesce(
                        col_description(
                            (array_to_string(parsed.ids[1:2],'.'))::regclass,
                            ordinal_position
                        ),

                        util.doc('@' || data_type::regtype)
                    )
                    from information_schema.columns
                    where
                    table_schema = parsed.ids[1]
                    and table_name = parsed.ids[2]
                    and column_name = parsed.ids[3]

                )
            else null
            end
            from parsed
        )

    -- unknown pattern
    else null
    end;

    if a is null then
        raise warning 'WARN %: unable to find description', cls_;
    end if;
    return a;
exception
    when others then
        raise warning 'ERR %: %', cls_, sqlerrm;
        return null;
end;
$$;

comment on function util.doc_(text)
is '
    retrieves descriptions of a {cls} for patterns
    schema.proc(...) for regprocedure,
    schema.table.column for column,
    schema.entity/entity for others (table, type, enum, proc,...)
';



create or replace function util.doc (
    text_ text
)
    returns text
    language sql
    stable
as $$
    select array_to_string(array_agg(ts.t), ' ', '')
    from (
        select case
        when t like '@%' and left(t,2)='@@'
        then right(t, -1)

        when t like '@%'
        then
            replace(t,
                trim(trim(E'\r\n.,;' from t)),
                coalesce(
                    util.doc_(trim(trim(E'\r\n.,;' from substring(t from 2)))),
                    t
                )
            )
        else t
        end
        from unnest(string_to_array(text_, ' ')) t
    ) ts;
$$;

comment on function util.doc(text)
is '
    Parses text for @{cls} and replaces it with its description
    Use @@ for @
';

create or replace function util.doc (
    cls_ regtype
)
    returns text
    language sql
    stable
as $$
    select util.doc(obj_description(cls_, 'pg_type'))
$$;

create or replace function util.doc (
    cls_ regclass
)
    returns text
    language sql
    stable
as $$
    select util.doc(obj_description(cls_, 'pg_class'))
$$;

create or replace function util.doc (
    cls_ regproc
)
    returns text
    language sql
    stable
as $$
    select util.doc(obj_description(cls_, 'pg_proc'))
$$;

create or replace function util.doc (
    cls_ regprocedure
)
    returns text
    language sql
    stable
as $$
    select util.doc(obj_description(cls_, 'pg_proc'))
$$;


\if :test
    create table tests.foo (a int, b jsonb);
    comment on table tests.foo is 'TABLE_FOO @tests.foo.a';
    comment on column tests.foo.a is 'COLUMN_FOO.A';

    create type tests.foo_enum_t as enum ('aa','bb');
    comment on type tests.foo_enum_t is 'FOO_ENUM_T';

    create type tests.foo_it as (a int, b int);
    comment on type tests.foo_it is 'FOO_IT @tests.foo_enum_t';

    create function tests.foo (tests.foo_it) returns text language sql as $$ select null $$;
    comment on function tests.foo(tests.foo_it)
    is '
        FUNCTION_FOO
        @tests.foo_it
        @tests.foo
        @tests.bar
        @tests.foo.b

        @tests.unknown
        @tests.unknown(int)
        @@tests.foo.b
    ';

    create function tests.bar (tests.foo_it) returns text language sql as $$ select null $$;
    comment on function tests.bar(tests.foo_it) is 'FUNCTION_BAR';

    -- select util.doc('tests.foo_enum_t'::regtype);
    -- select util.doc('tests.foo'::regproc);

    create function tests.test_util_doc()
        returns setof text
        language plpgsql
    as $$
    declare
        t text = util.doc('tests.foo'::regproc);
    begin
        return next ok(position('FUNCTION_FOO' in t)>0, 'gets function desc');
        return next ok(position('FOO_IT' in t)>0, 'gets user-type');
        return next ok(position('FOO_ENUM_T' in t)>0, 'gets enum');
        return next ok(position('TABLE_FOO' in t)>0, 'gets table');
        return next ok(position('FUNCTION_BAR' in t)>0, 'gets function');
        return next ok(position('COLUMN_FOO.A' in t)>0, 'gets column');
        return next ok(position('Binary JSON' in t)>0, 'gets column data-type');
        return next ok(position('@tests.unknown' in t)>0, 'ignores unknown identifier');
        return next ok(position('@tests.unknown(int)' in t)>0, 'ignores unknown function');
        return next ok(position('@tests.foo.b' in t)>0, 'replaces @@ into @');
    end;
    $$;

\endif

\endif