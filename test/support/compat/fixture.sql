-- PostgREST-shaped compatibility fixture. Test harness only.
-- Tables, column lists and seed rows are ported from PostgREST's
-- test/spec/fixtures/{schema,data}.sql (v14) with upstream names kept, so recorded
-- scenarios line up with upstream specs. Tables marked "PgRest" are additions.
CREATE EXTENSION IF NOT EXISTS citext;

CREATE SCHEMA test;
SET search_path = test, public;

CREATE TYPE status_enum AS ENUM ('draft', 'active', 'archived');

CREATE TABLE items (
  id bigserial PRIMARY KEY
);

CREATE TABLE complex_items (
  id bigint PRIMARY KEY,
  name text,
  settings jsonb,
  arr_data integer[],
  "field-with_sep" integer DEFAULT 1 NOT NULL,
  tags text[]
);

CREATE TABLE clients (
  id integer PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE projects (
  id integer PRIMARY KEY,
  name text NOT NULL CONSTRAINT projects_name_length CHECK (char_length(name) <= 100),
  client_id integer,
  CONSTRAINT client FOREIGN KEY (client_id) REFERENCES clients (id)
);

CREATE TABLE tasks (
  id integer PRIMARY KEY,
  name text NOT NULL,
  project_id integer,
  CONSTRAINT project FOREIGN KEY (project_id) REFERENCES projects (id)
);

CREATE TABLE users (
  id integer PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE users_tasks (
  user_id integer NOT NULL REFERENCES users (id),
  task_id integer NOT NULL REFERENCES tasks (id),
  PRIMARY KEY (task_id, user_id)
);

CREATE TABLE comments (
  id integer PRIMARY KEY,
  commenter_id integer NOT NULL,
  user_id integer NOT NULL,
  task_id integer NOT NULL,
  content text NOT NULL,
  CONSTRAINT "user" FOREIGN KEY (commenter_id) REFERENCES users (id),
  -- composite FK, declared in the resource by the Task 7 `relationships:` option
  CONSTRAINT comments_task_id_fkey FOREIGN KEY (task_id, user_id)
    REFERENCES users_tasks (task_id, user_id)
);

CREATE TABLE files (
  project_id integer NOT NULL,
  filename text NOT NULL,
  content text NOT NULL,
  PRIMARY KEY (project_id, filename)
);

CREATE TABLE touched_files (
  user_id integer NOT NULL,
  task_id integer NOT NULL,
  project_id integer NOT NULL,
  filename text NOT NULL,
  CONSTRAINT fk_users_tasks FOREIGN KEY (user_id, task_id)
    REFERENCES users_tasks (user_id, task_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_upload FOREIGN KEY (project_id, filename)
    REFERENCES files (project_id, filename) ON DELETE CASCADE ON UPDATE CASCADE,
  PRIMARY KEY (user_id, task_id, project_id, filename)
);

CREATE TABLE students (
  id int,
  code text,
  name text,
  PRIMARY KEY (id, code)
);

CREATE TABLE students_info (
  id int,
  code text,
  address text,
  PRIMARY KEY (id, code),
  FOREIGN KEY (code, id) REFERENCES students (code, id) ON DELETE CASCADE
);

CREATE TABLE country (
  id int PRIMARY KEY,
  name text
);

CREATE TABLE capital (
  id int PRIMARY KEY,
  name text,
  country_id int UNIQUE,
  FOREIGN KEY (country_id) REFERENCES country (id)
);

CREATE TABLE family_tree (
  id text NOT NULL PRIMARY KEY,
  name text NOT NULL,
  parent text,
  CONSTRAINT pptr FOREIGN KEY (parent) REFERENCES family_tree (id)
);

-- Not in the task's table list, but organizations.manager_id references it upstream.
CREATE TABLE managers (
  id integer PRIMARY KEY,
  name text
);

CREATE TABLE organizations (
  id integer PRIMARY KEY,
  name text,
  referee integer REFERENCES organizations (id),
  auditor integer REFERENCES organizations (id),
  manager_id integer,
  CONSTRAINT manager FOREIGN KEY (manager_id) REFERENCES managers (id)
);

CREATE TABLE addresses (
  id int NOT NULL UNIQUE,
  address text NOT NULL
);

CREATE TABLE orders (
  id int NOT NULL UNIQUE,
  name text NOT NULL,
  billing_address_id int,
  shipping_address_id int,
  CONSTRAINT billing FOREIGN KEY (billing_address_id) REFERENCES addresses (id),
  CONSTRAINT shipping FOREIGN KEY (shipping_address_id) REFERENCES addresses (id)
);

CREATE TABLE entities (
  id integer PRIMARY KEY,
  name text,
  arr integer[],
  text_search_vector tsvector
);

CREATE TABLE child_entities (
  id integer PRIMARY KEY,
  name text,
  parent_id integer REFERENCES entities (id)
);

CREATE TABLE grandchild_entities (
  id integer PRIMARY KEY,
  name text,
  parent_id integer REFERENCES child_entities (id),
  or_starting_col text,
  and_starting_col text,
  jsonb_col jsonb
);

CREATE TABLE tsearch (
  text_search_vector tsvector
);

CREATE TABLE ranges (
  id integer PRIMARY KEY,
  range int4range
);

CREATE TABLE compound_pk (
  PRIMARY KEY (k1, k2),
  k1 integer NOT NULL,
  k2 text NOT NULL,
  extra integer
);

-- Prefer: timezone and max-affected (upstream schema.sql / data.sql, verbatim).
CREATE TABLE timestamps (
  t timestamp with time zone
);

CREATE TABLE tiobe_pls (
  name text PRIMARY KEY,
  rank smallint
);

CREATE TABLE no_pk (
  a character varying,
  b character varying
);

-- PUT (upstream schema.sql / data.sql, verbatim): composite key, key-only table, camelCase
-- names, a self-referencing table and a partitioned table with a composite key.
CREATE TABLE employees (
  first_name text,
  last_name text,
  salary money,
  company text,
  occupation text,
  PRIMARY KEY (first_name, last_name)
);

CREATE TABLE only_pk (
  id integer PRIMARY KEY
);

CREATE TABLE "UnitTest" (
  "idUnitTest" integer PRIMARY KEY,
  "nameUnitTest" text
);

CREATE TABLE web_content (
  id integer,
  name text,
  p_web_id integer REFERENCES web_content (id),
  PRIMARY KEY (id)
);

CREATE TABLE car_models (
  name varchar(64) NOT NULL,
  year int NOT NULL
) PARTITION BY LIST (year);

CREATE TABLE car_models_2021 PARTITION OF car_models FOR VALUES IN (2021);
CREATE TABLE car_models_default PARTITION OF car_models FOR VALUES IN (1981, 1997, 2001, 2013);

CREATE TABLE car_brands (
  name varchar(64) PRIMARY KEY
);

ALTER TABLE car_models ADD PRIMARY KEY (name, year);
ALTER TABLE car_models ADD COLUMN car_brand_name varchar(64) REFERENCES car_brands (name);

-- PgRest: a table related to another both directly and through a junction
-- (ambiguous embed), with no many_to_many anywhere.
CREATE TABLE ambig_a (
  id integer PRIMARY KEY,
  name text
);

CREATE TABLE ambig_b (
  id integer PRIMARY KEY,
  name text,
  a_id integer REFERENCES ambig_a (id)
);

CREATE TABLE ambig_ab (
  a_id integer NOT NULL REFERENCES ambig_a (id),
  b_id integer NOT NULL REFERENCES ambig_b (id),
  PRIMARY KEY (a_id, b_id)
);

-- PgRest: nullable foreign key, for embed and !inner scenarios.
CREATE TABLE nullable_fk_parent (
  id integer PRIMARY KEY,
  name text
);

CREATE TABLE nullable_fk_child (
  id integer PRIMARY KEY,
  name text,
  parent_id integer REFERENCES nullable_fk_parent (id)
);

-- PgRest: committed rows with awkward CSV content (Phase 2 CSV scenarios).
CREATE TABLE csv_edge (
  id integer PRIMARY KEY,
  label text,
  note text
);

-- PgRest: committed rows whose CSV form is byte-compared with PostgREST (media_types scenarios).
CREATE TABLE csv_edge_cases (
  id integer PRIMARY KEY,
  txt text,
  js jsonb,
  arr integer[]
);

CREATE SEQUENCE code_seq;

CREATE FUNCTION next_code() RETURNS text
  LANGUAGE sql
  AS $$ SELECT 'C' || lpad(nextval('test.code_seq')::text, 4, '0') $$;

-- PgRest: columns with defaults, for `Prefer: missing=default`.
CREATE TABLE defaults_demo (
  id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  label text,
  code text DEFAULT test.next_code(),
  note text DEFAULT 'x',
  created_at timestamptz DEFAULT now(),
  double_id integer GENERATED ALWAYS AS (id * 2) STORED
);

-- PgRest: type coverage (P-H3).
CREATE TABLE type_cases (
  id integer PRIMARY KEY,
  status status_enum,
  email citext,
  qty int4,
  at timestamptz,
  price numeric(10, 2),
  code char(3),
  bits bit(3)
);
CREATE INDEX type_cases_qty_idx ON type_cases (qty);
CREATE INDEX type_cases_status_idx ON type_cases (status);
CREATE INDEX type_cases_email_idx ON type_cases (email);

-- PgRest: sensitive columns (S-M2, S-H5).
CREATE TABLE accounts (
  id integer PRIMARY KEY,
  email text UNIQUE,
  hashed_password text,
  role text CHECK (role IN ('user', 'admin')),
  owner_id text
);

-- pg-safeupdate tables (upstream schema.sql); the `safeupdate` scenarios run against these.
CREATE TABLE safe_update_items (
  id int PRIMARY KEY,
  name text,
  observation text
);
CREATE TABLE safe_delete_items (
  id int PRIMARY KEY,
  name text,
  observation text
);
CREATE TABLE unsafe_update_items (
  id int PRIMARY KEY,
  name text,
  observation text
);
CREATE TABLE unsafe_delete_items (
  id int PRIMARY KEY,
  name text,
  observation text
);

-- Response GUC fixtures (upstream schema.sql: RpcSpec "GUC headers" and `stuff` triggers).
CREATE SCHEMA private;
CREATE TABLE private.stuff (
  id integer PRIMARY KEY,
  name text
);
CREATE VIEW test.stuff AS SELECT * FROM private.stuff;
CREATE TABLE loc_test (
  id int PRIMARY KEY,
  c text
);
-- PgRest: probes an AFTER trigger's GUC (upstream's `loc_test` has no trigger).
CREATE TABLE pgrest_after_loc (
  id integer PRIMARY KEY,
  c text
);

-- PgRest: a numeric primary key (PUT compares keys by value: 1.50 is 1.5).
CREATE TABLE put_numeric (
  n numeric PRIMARY KEY,
  v text
);

-- PgRest: a BEFORE trigger sets response GUCs while a PUT upserts (insert and update).
CREATE TABLE put_guc (
  id integer PRIMARY KEY,
  c text
);

CREATE FUNCTION put_guc_set() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('response.headers', '[{"X-Put": "from-trigger"}]', true);
      PERFORM set_config('response.status', '202', true);
      RETURN NEW;
    END;
    $$;

CREATE TRIGGER put_guc_before BEFORE INSERT OR UPDATE ON put_guc
  FOR EACH ROW EXECUTE FUNCTION put_guc_set();

-- Aggregate fixtures (upstream schema.sql, AggregateFunctionsSpec).
create table test.trash(
  id int primary key
);

create table test.trash_details(
  id int primary key references test.trash(id),
  jsonb_col jsonb
);

create table project_invoices (
  id int primary key
, invoice_total numeric
, project_id integer references projects(id)
);

create table budget_categories (
  id int primary key
, category_name text
, budget_owner text
, budget_amount numeric
);

create table budget_expenses (
  id int primary key
, expense_amount numeric
, budget_category_id integer references budget_categories(id)
);

create table factories (
  id int primary key,
  name text
);

create table process_categories (
  id int primary key,
  name text
);

create table processes (
  id int primary key,
  name text,
  factory_id int references factories(id),
  category_id int references process_categories(id)
);

create table process_costs (
  process_id int references processes(id) primary key,
  cost numeric
);

create table supervisors (
  id int primary key,
  name text
);

create table process_supervisor (
  process_id int references processes(id),
  supervisor_id int references supervisors(id),
  primary key (process_id, supervisor_id)
);

create table factory_buildings (
  id int primary key,
  code char(4),
  size numeric,
  "type" char(1),
  factory_id int references factories(id),
  inspections jsonb
);

-- Seed data (upstream rows, in FK order)

INSERT INTO items SELECT FROM generate_series(1, 15);

INSERT INTO complex_items (id, name, settings, arr_data, tags) VALUES
  (1, 'One', '{"foo":{"int":1,"bar":"baz"}}', '{1}', '{a}'),
  (2, 'Two', '{"foo":{"int":1,"bar":"baz"}}', '{1,2}', '{a,b}');
INSERT INTO complex_items (id, name, settings, arr_data, "field-with_sep", tags) VALUES
  (3, 'Three', '{"foo":{"int":1,"bar":"baz"}}', '{1,2,3}', 3, '{a,b,c}');

INSERT INTO clients VALUES (1, 'Microsoft'), (2, 'Apple');

INSERT INTO projects VALUES
  (1, 'Windows 7', 1),
  (2, 'Windows 10', 1),
  (3, 'IOS', 2),
  (4, 'OSX', 2),
  (5, 'Orphan', NULL);

INSERT INTO tasks VALUES
  (1, 'Design w7', 1),
  (2, 'Code w7', 1),
  (3, 'Design w10', 2),
  (4, 'Code w10', 2),
  (5, 'Design IOS', 3),
  (6, 'Code IOS', 3),
  (7, 'Design OSX', 4),
  (8, 'Code OSX', 4);

INSERT INTO users VALUES
  (1, 'Angela Martin'),
  (2, 'Michael Scott'),
  (3, 'Dwight Schrute');

INSERT INTO users_tasks VALUES
  (1, 1), (1, 2), (1, 3), (1, 4),
  (2, 5), (2, 6), (2, 7),
  (3, 1), (3, 5);

INSERT INTO comments VALUES (1, 1, 2, 6, 'Needs to be delivered ASAP');

INSERT INTO files VALUES
  (1, 'command.com', '#include <unix.h>'),
  (1, 'autoexec.bat', '@ECHO OFF'),
  (1, 'io.sys', 'TODO'),
  (2, 'README.md', '# make $$$!'),
  (2, 'marketing.key', '$-$');

INSERT INTO touched_files VALUES
  (1, 1, 1, 'command.com'),
  (1, 1, 1, 'autoexec.bat'),
  (1, 1, 2, 'README.md'),
  (3, 1, 1, 'autoexec.bat');

INSERT INTO students (id, code, name) VALUES (1, '0001', 'John Doe'), (2, '0002', 'Jane Doe');
INSERT INTO students_info (id, code, address)
  VALUES (1, '0001', 'Street 1'), (2, '0002', 'Street 2');

INSERT INTO country (id, name) VALUES (1, 'Afghanistan'), (2, 'Algeria');
INSERT INTO capital (id, name, country_id) VALUES (1, 'Kabul', 1), (2, 'Algiers', 2);

INSERT INTO family_tree VALUES
  ('1', 'Parental Unit', NULL),
  ('2', 'Kid One', '1'),
  ('3', 'Kid Two', '1'),
  ('4', 'Grandkid One', '2'),
  ('5', 'Grandkid Two', '3');

INSERT INTO managers VALUES
  (1, 'Referee Manager'),
  (2, 'Auditor Manager'),
  (3, 'Acme Manager'),
  (4, 'Umbrella Manager'),
  (5, 'Cyberdyne Manager'),
  (6, 'Oscorp Manager');

INSERT INTO organizations VALUES
  (1, 'Referee Org', NULL, NULL, 1),
  (2, 'Auditor Org', NULL, NULL, 2),
  (3, 'Acme', 1, 2, 3),
  (4, 'Umbrella', 1, 2, 4),
  (5, 'Cyberdyne', 3, 4, 5),
  (6, 'Oscorp', 3, 4, 6);

INSERT INTO addresses VALUES
  (1, 'address 1'), (2, 'address 2'), (3, 'address 3'), (4, 'address 4');

INSERT INTO orders VALUES (1, 'order 1', 1, 2), (2, 'order 2', 3, 4);

INSERT INTO entities VALUES
  (1, 'entity 1', '{1}', '''bar'':2 ''foo'':1'),
  (2, 'entity 2', '{1,2}', '''baz'':1 ''qux'':2'),
  (3, 'entity 3', '{1,2,3}', NULL),
  (4, NULL, NULL, NULL);

INSERT INTO child_entities VALUES
  (1, 'child entity 1', 1),
  (2, 'child entity 2', 1),
  (3, 'child entity 3', 2),
  (4, 'child entity 4', 1),
  (5, 'child entity 5', 1),
  (6, 'child entity 6', 2);

INSERT INTO grandchild_entities VALUES
  (1, 'grandchild entity 1', 1, NULL, NULL, NULL),
  (2, 'grandchild entity 2', 1, NULL, NULL, NULL),
  (3, 'grandchild entity 3', 2, NULL, NULL, NULL),
  (4, '(grandchild,entity,4)', 2, NULL, NULL, '{"a": {"b":"foo"}}'),
  (5, '(grandchild,entity,5)', 2, NULL, NULL, '{"b":"bar"}');

INSERT INTO tsearch VALUES
  (to_tsvector('It''s kind of fun to do the impossible')),
  (to_tsvector('But also fun to do what is possible')),
  (to_tsvector('Fat cats ate rats')),
  (to_tsvector('french', 'C''est un peu amusant de faire l''impossible')),
  (to_tsvector('german', 'Es ist eine Art Spaß, das Unmögliche zu machen'));

INSERT INTO ranges VALUES
  (1, '[1,3]'), (2, '[3,6]'), (3, '[6,9]'), (4, '[9,12]'), (5, NULL);

INSERT INTO no_pk VALUES (NULL, NULL), ('1', '0'), ('2', '0');

INSERT INTO timestamps VALUES ('2023-10-18 12:37:59.611000+0000');
INSERT INTO timestamps VALUES ('2023-10-18 14:37:59.611000+0000');
INSERT INTO timestamps VALUES ('2023-10-18 16:37:59.611000+0000');

INSERT INTO tiobe_pls VALUES ('Java', 1), ('C', 2), ('Python', 4);

INSERT INTO employees VALUES
  ('Frances M.', 'Roe', '24000', 'One-Up Realty', 'Author'),
  ('Daniel B.', 'Lyon', '36000', 'Dubrow''s Cafeteria', 'Packer'),
  ('Edwin S.', 'Smith', '48000', 'Pro Garden Management', 'Marine biologist');

INSERT INTO only_pk VALUES (1), (2);

INSERT INTO "UnitTest" VALUES (1, 'unit test 1');

INSERT INTO web_content VALUES (5, 'wat', NULL);
INSERT INTO web_content VALUES (0, 'tardis', 5);
INSERT INTO web_content VALUES (1, 'fezz', 0);
INSERT INTO web_content VALUES (2, 'foo', 0);
INSERT INTO web_content VALUES (3, 'bar', 0);
INSERT INTO web_content VALUES (4, 'wut', 1);

INSERT INTO car_brands VALUES ('DMC'), ('Ferrari'), ('Lamborghini');
INSERT INTO car_models (name, year) VALUES
  ('DeLorean', 1981), ('F310-B', 1997), ('Veneno', 2013), ('Murcielago', 2001);
UPDATE car_models SET car_brand_name = 'DMC' WHERE name = 'DeLorean';
UPDATE car_models SET car_brand_name = 'Ferrari' WHERE name = 'F310-B';
UPDATE car_models SET car_brand_name = 'Lamborghini' WHERE name IN ('Veneno', 'Murcielago');

INSERT INTO ambig_a VALUES (1, 'a1'), (2, 'a2');
INSERT INTO ambig_b VALUES (1, 'b1', 1), (2, 'b2', 1), (3, 'b3', NULL);
INSERT INTO ambig_ab VALUES (1, 1), (1, 3), (2, 2);

INSERT INTO nullable_fk_parent VALUES (1, 'parent 1'), (2, 'parent 2');
INSERT INTO nullable_fk_child VALUES
  (1, 'child 1', 1),
  (2, 'child 2', 1),
  (3, 'orphan child', NULL);

INSERT INTO csv_edge VALUES
  (1, 'comma, inside', 'plain'),
  (2, 'quote "inside"', 'plain'),
  (3, E'line\nbreak', E'carriage\r\nreturn'),
  (4, 'unicode: héllo ✓ 日本', 'plain'),
  (5, NULL, 'null label'),
  (6, '', 'empty label'),
  (7, 'both, "mixed"', E'all,"of"\nthem');

INSERT INTO csv_edge_cases VALUES
  (1, 'a,b', NULL, NULL),
  (2, 'say "hi"', NULL, NULL),
  (3, E'line1\nline2', NULL, NULL),
  (4, 'héllo ✓ 日本', NULL, NULL),
  (5, NULL, NULL, NULL),
  (6, '', NULL, NULL),
  (7, '",' || '"', NULL, NULL),
  (8, NULL, '{"k":"v,w","q":"\""}', '{1,2}'),
  (9, NULL, NULL, '{}');

INSERT INTO defaults_demo (label) VALUES ('seed');

INSERT INTO type_cases VALUES
  (1, 'draft', 'Alice@Example.com', 10, '2024-01-01T00:00:00Z', 9.99, 'abc', B'101'),
  (2, 'active', 'bob@example.com', 20, '2024-06-15T12:30:00Z', 19.50, 'ab', B'010'),
  (3, 'archived', NULL, NULL, NULL, NULL, NULL, NULL);

INSERT INTO accounts VALUES
  (1, 'alice@example.com', 'hash-alice', 'user', 'owner-1'),
  (2, 'bob@example.com', 'hash-bob', 'user', 'owner-2'),
  (3, 'root@example.com', 'hash-root', 'admin', 'owner-1');

INSERT INTO safe_update_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO safe_delete_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO unsafe_update_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO unsafe_delete_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO private.stuff (id, name) VALUES (1, 'stuff 1');
INSERT INTO pgrest_after_loc VALUES (1, 'a');
INSERT INTO put_guc VALUES (1, 'a');
INSERT INTO put_numeric VALUES (1.50, 'a');

-- Aggregate fixtures (upstream data.sql).
INSERT INTO trash(id) VALUES (1), (2), (3);
INSERT INTO trash_details(id,jsonb_col) VALUES (1,'{"key": 10}'), (2,'{"key": 6}'), (3,'{"key": 8}');

INSERT INTO project_invoices VALUES (1, 100, 1);
INSERT INTO project_invoices VALUES (2, 200, 1);
INSERT INTO project_invoices VALUES (3, 500, 2);
INSERT INTO project_invoices VALUES (4, 700, 2);
INSERT INTO project_invoices VALUES (5, 1200, 3);
INSERT INTO project_invoices VALUES (6, 2000, 3);
INSERT INTO project_invoices VALUES (7, 100, 4);
INSERT INTO project_invoices VALUES (8, 4000, 4);

INSERT INTO budget_categories VALUES (1, 'Beanie Babies', 'Brian Smith', 1000.31);
INSERT INTO budget_categories VALUES (2, 'DVDs', 'Jane Clarkson', 2000.12);
INSERT INTO budget_categories VALUES (3, 'Pizza', 'Brian Smith', 1000.11);
INSERT INTO budget_categories VALUES (4, 'Opera Tickets', 'Jane Clarkson', 7000.41);
INSERT INTO budget_categories VALUES (5, 'Nuclear Fusion Research', 'Sally Hughes', 500.23);
INSERT INTO budget_categories VALUES (6, 'T-5hirts', 'Dana de Groot', 500.33);

INSERT INTO budget_expenses VALUES (1, 200.26, 1);
INSERT INTO budget_expenses VALUES (2, 400.26, 3);
INSERT INTO budget_expenses VALUES (3, 100.22, 4);
INSERT INTO budget_expenses VALUES (5, 900.27, 5);

INSERT INTO factories VALUES (1, 'Factory A');
INSERT INTO factories VALUES (2, 'Factory B');
INSERT INTO factories VALUES (3, 'Factory C');
INSERT INTO factories VALUES (4, 'Factory D');

INSERT INTO process_categories VALUES (1, 'Batch');
INSERT INTO process_categories VALUES (2, 'Mass');

INSERT INTO processes VALUES (1, 'Process A1', 1, 1);
INSERT INTO processes VALUES (2, 'Process A2', 1, 2);
INSERT INTO processes VALUES (3, 'Process B1', 2, 1);
INSERT INTO processes VALUES (4, 'Process B2', 2, 1);
INSERT INTO processes VALUES (5, 'Process C1', 3, 2);
INSERT INTO processes VALUES (6, 'Process C2', 3, 2);
INSERT INTO processes VALUES (7, 'Process XX', 3, 2);
INSERT INTO processes VALUES (8, 'Process YY', 3, 2);

INSERT INTO process_costs VALUES (1, 150.00);
INSERT INTO process_costs VALUES (2, 200.00);
INSERT INTO process_costs VALUES (3, 180.00);
INSERT INTO process_costs VALUES (4, 70.00);
INSERT INTO process_costs VALUES (5, 40.00);
INSERT INTO process_costs VALUES (6, 70.00);
INSERT INTO process_costs VALUES (8, 40.00);

INSERT INTO supervisors VALUES (1, 'Mary');
INSERT INTO supervisors VALUES (2, 'John');
INSERT INTO supervisors VALUES (3, 'Peter');
INSERT INTO supervisors VALUES (4, 'Sarah');
INSERT INTO supervisors VALUES (5, 'Jane');

INSERT INTO process_supervisor VALUES (1, 1);
INSERT INTO process_supervisor VALUES (2, 2);
INSERT INTO process_supervisor VALUES (3, 3);
INSERT INTO process_supervisor VALUES (3, 4);
INSERT INTO process_supervisor VALUES (4, 1);
INSERT INTO process_supervisor VALUES (4, 2);
INSERT INTO process_supervisor VALUES (5, 3);
INSERT INTO process_supervisor VALUES (6, 3);

INSERT INTO factory_buildings VALUES (1, 'A001', 150, 'A', 1, '{"ins": "2024C", "pending": true}');
INSERT INTO factory_buildings VALUES (2, 'A002', 200, 'A', 1, '{"ins": "2025A", "pending": true}');
INSERT INTO factory_buildings VALUES (3, 'B001', 50, 'B', 2, '{"ins": "2025A", "pending": true}');
INSERT INTO factory_buildings VALUES (4, 'B002', 120, 'C', 2, '{"ins": "2023A"}');
INSERT INTO factory_buildings VALUES (5, 'C001', 240, 'B', 3, '{"ins": "2022B"}' );
INSERT INTO factory_buildings VALUES (6, 'D001', 310, 'A', 4, '{"ins": "2024C", "pending": true}');

-- Functions (RPC), ported from upstream schema.sql with upstream volatility.
CREATE FUNCTION getallprojects() RETURNS SETOF projects
    LANGUAGE sql
    AS $_$ SELECT * FROM test.projects; $_$ ROWS 2019;

CREATE FUNCTION getproject(id int) RETURNS SETOF projects
    LANGUAGE sql
    AS $_$ SELECT * FROM test.projects WHERE id = $1; $_$;

CREATE FUNCTION setprojects(id_l int, id_h int, name text) RETURNS SETOF projects
    LANGUAGE sql
    AS $_$ UPDATE test.projects SET name = $3 WHERE id >= $1 AND id <= $2 RETURNING *; $_$;

CREATE FUNCTION getitemrange(min bigint, max bigint) RETURNS SETOF items
    LANGUAGE sql STABLE
    AS $_$ SELECT * FROM test.items WHERE id > $1 AND id <= $2; $_$;

CREATE FUNCTION delete_items_returns_setof() RETURNS SETOF items
    LANGUAGE sql
    AS $$ DELETE FROM test.items WHERE id <= 15 RETURNING *; $$;

CREATE FUNCTION delete_items_returns_table() RETURNS TABLE(id bigint)
    LANGUAGE sql
    AS $$ DELETE FROM test.items WHERE id <= 15 RETURNING *; $$;

CREATE FUNCTION delete_items_returns_void() RETURNS void
    LANGUAGE sql
    AS $$ DELETE FROM test.items; $$;

CREATE FUNCTION overloaded_unnamed_param(json) RETURNS json
    LANGUAGE sql
    AS $$ SELECT $1; $$;

CREATE FUNCTION overloaded_unnamed_param() RETURNS integer
    LANGUAGE sql
    AS $$ SELECT 1; $$;

CREATE FUNCTION overloaded_unnamed_param(x integer, y integer) RETURNS integer
    LANGUAGE sql
    AS $$ SELECT x + y; $$;

CREATE FUNCTION add_them(a integer, b integer) RETURNS integer
    LANGUAGE sql
    AS $$ SELECT a + b; $$;

CREATE FUNCTION sayhello(name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$ SELECT 'Hello, ' || $1; $_$;

CREATE FUNCTION noparamsproc() RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT a FROM (VALUES ('Return value of no parameters procedure.')) s(a); $$;

CREATE FUNCTION unnamed_json_param(json) RETURNS json
    LANGUAGE sql
    AS $$ SELECT $1; $$;

CREATE FUNCTION named_json_param(data json) RETURNS json
    LANGUAGE sql
    AS $$ SELECT data; $$;

CREATE FUNCTION overloaded_same_args(arg integer) RETURNS json
    LANGUAGE sql
    AS $$ SELECT json_build_object('type', pg_typeof(arg), 'value', arg); $$;

CREATE FUNCTION overloaded_same_args(arg xml) RETURNS json
    LANGUAGE sql
    AS $$ SELECT json_build_object('type', pg_typeof(arg), 'value', arg); $$;

CREATE FUNCTION overloaded_same_args(arg text, num integer DEFAULT 0) RETURNS json
    LANGUAGE sql
    AS $$ SELECT json_build_object('type', pg_typeof(arg), 'value', arg); $$;

-- PgRest: overloads over a user-defined type (pins the type spelling of PGRST203).
CREATE FUNCTION overloaded_enum_arg(arg status_enum) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT arg::text; $$;

CREATE FUNCTION overloaded_enum_arg(arg text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT arg; $$;

CREATE FUNCTION variadic_param(VARIADIC v text[] DEFAULT '{}') RETURNS text[]
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT v $$;

CREATE FUNCTION single_out_param(num int, OUT num_plus_one int)
    LANGUAGE sql
    AS $$ SELECT num + 1; $$;

CREATE FUNCTION single_inout_param(INOUT num int)
    LANGUAGE sql
    AS $$ SELECT num + 1; $$;

CREATE FUNCTION many_out_params(OUT my_json json, OUT num int, OUT str text)
    LANGUAGE sql
    AS $$ SELECT '{"a": 1, "b": "two"}'::json, 3, 'four'::text; $$;

CREATE FUNCTION ret_void() RETURNS void LANGUAGE sql AS '';

CREATE SEQUENCE callcounter_count START 1;

-- Volatile and writes (advances a sequence).
CREATE FUNCTION callcounter() RETURNS bigint
    LANGUAGE sql
    AS $_$ SELECT nextval('test.callcounter_count'); $_$;

-- PgRest: result-scope and timeout fixtures (Phase 2 Tasks 4 and 6).
CREATE FUNCTION scoped_projects() RETURNS SETOF projects
    LANGUAGE sql STABLE
    AS $$ SELECT * FROM test.projects; $$;

CREATE FUNCTION fabricated_projects() RETURNS SETOF projects
    LANGUAGE sql STABLE
    AS $$
      SELECT * FROM test.scoped_projects()
      UNION ALL
      SELECT (ROW(9999, 'fake', 1)::test.projects).*;
    $$;

-- Rows in a deliberately non-key order, for the row-order guarantee of a call.
CREATE FUNCTION ranked_projects() RETURNS SETOF projects
    LANGUAGE sql STABLE
    AS $$ SELECT * FROM test.projects ORDER BY id DESC; $$;

CREATE FUNCTION reowned_projects() RETURNS SETOF projects
    LANGUAGE sql STABLE
    AS $$ SELECT id, name, 1 AS client_id FROM test.projects; $$;

CREATE FUNCTION make_project(name text) RETURNS projects
    LANGUAGE sql VOLATILE
    AS $$
      INSERT INTO test.projects (id, name)
      VALUES ((SELECT coalesce(max(id), 0) + 1 FROM test.projects), make_project.name)
      RETURNING *;
    $$;

CREATE FUNCTION sleep_for(s float8) RETURNS void
    LANGUAGE sql STABLE
    AS $$ SELECT pg_sleep(s); $$;

-- Response GUCs (Phase 2 Task 6b): `response.headers` / `response.status`, set by functions and
-- triggers. Upstream's are the first eight; `guc_status` and `status_then_raise` are PgRest's.
CREATE FUNCTION get_projects_and_guc_headers() RETURNS SETOF projects
    LANGUAGE sql
    AS $$
      SET LOCAL "response.headers" = '[{"X-Test": "key1=val1; someValue; key2=val2"}, {"X-Test-2": "key1=val1"}]';
      SELECT * FROM test.projects;
    $$;

CREATE FUNCTION get_int_and_guc_headers(num int) RETURNS integer
    LANGUAGE sql
    AS $$
      SET LOCAL "response.headers" = '[{"X-Test":"key1=val1; someValue; key2=val2"},{"X-Test-2":"key1=val1"}]';
      SELECT num;
    $$;

CREATE FUNCTION bad_guc_headers_1() RETURNS void
    LANGUAGE sql
    AS $$ SET LOCAL "response.headers" = '{"X-Test": "invalid structure for headers"}'; $$;

CREATE FUNCTION bad_guc_headers_2() RETURNS void
    LANGUAGE sql
    AS $$ SET LOCAL "response.headers" = '["invalid", "structure", "for", "headers"]'; $$;

CREATE FUNCTION bad_guc_headers_3() RETURNS void
    LANGUAGE sql
    AS $$ SET LOCAL "response.headers" = '{"X-Test": "invalid", "X-Test-2": "structure", "X-Test-3": "for headers"}'; $$;

CREATE FUNCTION set_cookie_twice() RETURNS void
    LANGUAGE sql
    AS $$
      SET LOCAL "response.headers" = '[{"Set-Cookie": "sessionid=38afes7a8; HttpOnly; Path=/"}, {"Set-Cookie": "id=a3fWa; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly"}]';
    $$;

CREATE FUNCTION send_body_status_403() RETURNS json
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('response.status', '403', true);
      RETURN json_build_object('message', 'invalid user or password');
    END;
    $$;

CREATE FUNCTION send_bad_status() RETURNS json
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('response.status', 'bad', true);
      RETURN NULL;
    END;
    $$;

-- PgRest: any status text, to record PostgREST's reading of edge forms.
CREATE FUNCTION guc_status(code text) RETURNS void
    LANGUAGE plpgsql
    AS $$ BEGIN PERFORM set_config('response.status', code, true); END; $$;

-- PgRest: both GUCs malformed; PostgREST decodes the status first (PGRST112).
CREATE FUNCTION guc_both_bad() RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('response.headers', '{}', true);
      PERFORM set_config('response.status', 'bad', true);
    END;
    $$;

-- PgRest: a status set and then an error; the error wins.
CREATE FUNCTION status_then_raise() RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config('response.status', '403', true);
      RAISE EXCEPTION 'boom';
    END;
    $$;

CREATE FUNCTION location_for_stuff() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
    BEGIN
      INSERT INTO private.stuff VALUES (new.id, new.name);
      IF new.id IS NOT NULL THEN
        PERFORM set_config(
          'response.headers',
          format('[{"Location": "/%s?id=eq.%s&overriden=true"}]', tg_table_name, new.id),
          true
        );
      END IF;
      RETURN new;
    END
    $$;
CREATE TRIGGER location_for_stuff INSTEAD OF INSERT ON test.stuff
  FOR EACH ROW EXECUTE PROCEDURE test.location_for_stuff();

CREATE FUNCTION status_205_for_updated_stuff() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
    BEGIN
      UPDATE private.stuff SET id = new.id, name = new.name;
      PERFORM set_config('response.status', '205', true);
      RETURN new;
    END
    $$;
CREATE TRIGGER status_205_for_updated_stuff INSTEAD OF UPDATE ON test.stuff
  FOR EACH ROW EXECUTE PROCEDURE test.status_205_for_updated_stuff();

-- PgRest: sets `response.headers` to any text, to probe malformed and hostile headers.
CREATE FUNCTION guc_headers_raw(raw text) RETURNS void
    LANGUAGE plpgsql
    AS $$ BEGIN PERFORM set_config('response.headers', raw, true); END; $$;

CREATE FUNCTION pgrest_after_loc_set_location() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM set_config(
        'response.headers',
        '[{"Location": "/pgrest_after_loc?id=eq.' || NEW.id || '&c=eq.' || NEW.c || '"}]',
        true
      );
      RETURN NEW;
    END;
    $$;

CREATE TRIGGER pgrest_after_loc_location_override AFTER INSERT ON pgrest_after_loc
  FOR EACH ROW EXECUTE FUNCTION pgrest_after_loc_set_location();

-- PgRest: never introspected (extension-owned, trigger-returning).
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA test;

CREATE FUNCTION touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN RETURN NEW; END; $$;

create or replace function test.raise_pt402() returns void as $$
begin
  raise sqlstate 'PT402' using message = 'Payment Required',
                               detail = 'Quota exceeded',
                               hint = 'Upgrade your plan';
end;
$$ language plpgsql;
create function raise_sqlstate_test1() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC","details":"DEF","hint":"XYZ"}',
      detail = '{"status":332,"status_text":"My Custom Status","headers":{"X-Header":"str"}}';
end
$$;

create function raise_sqlstate_test2() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC"}',
      detail = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

create function raise_sqlstate_test3() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC"}',
      detail = '{"status":404,"headers":{"X-Header":"str"}}';
end
$$;

create function raise_sqlstate_test4() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC"}',
      detail = '{"status":404,"status_text":"My Not Found","headers":{"X-Header":"str"}}';
end
$$;

create function raise_sqlstate_invalid_json_message() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = 'INVALID',
      detail = '{"status":332,"headers":{"X-Header":"str"}}';
end
$$;

create function raise_sqlstate_invalid_json_details() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC","details":"DEF"}',
      detail = 'INVALID';
end
$$;

create function raise_sqlstate_missing_details() returns void
  language plpgsql
  as $$
begin
    raise sqlstate 'PGRST' USING
      message = '{"code":"123","message":"ABC","details":"DEF"}';
end
$$;


-- Sweep fixtures: quoted identifiers, typed arguments and partially unnamed signatures.
CREATE TABLE "موارد" ("هویت" integer PRIMARY KEY);
CREATE FUNCTION "UpperEcho"("Input" text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT $1 $$;
CREATE FUNCTION typed_echo(flag boolean, amount numeric, day date, ids integer[], doc jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_build_object('flag', $1, 'amount', $2, 'day', $3, 'ids', $4, 'doc', $5)
$$;
CREATE FUNCTION partially_unnamed(integer, label text DEFAULT 'x') RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT $1::text || $2 $$;
CREATE FUNCTION raise_payload(msg text, det text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF det IS NULL THEN RAISE SQLSTATE 'PGRST' USING MESSAGE = msg;
  ELSE RAISE SQLSTATE 'PGRST' USING MESSAGE = msg, DETAIL = det;
  END IF;
END $$;

CREATE TABLE sponsors (id integer PRIMARY KEY);
CREATE TABLE competitors (id integer PRIMARY KEY, sponsor_id integer REFERENCES sponsors(id), full_name text NOT NULL);
CREATE VIEW test_null_pk_competitors_sponsors AS
SELECT c.id, s.id AS sponsor_id FROM competitors c LEFT JOIN sponsors s ON c.sponsor_id = s.id;
CREATE RULE test_null_pk_competitors_sponsors AS ON INSERT TO test_null_pk_competitors_sponsors DO INSTEAD
INSERT INTO competitors(id, full_name, sponsor_id) VALUES(new.id, 'Competitor without sponsor', new.sponsor_id)
RETURNING id, sponsor_id;

CREATE FUNCTION raise_state(state text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION USING ERRCODE = state, MESSAGE = 'custom state'; END $$;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER sweep_loopback FOREIGN DATA WRAPPER postgres_fdw
OPTIONS (host '127.0.0.1', port '5432', dbname 'pgrest_compat');
CREATE USER MAPPING FOR postgres SERVER sweep_loopback OPTIONS (user 'postgres', password 'postgres');
CREATE FOREIGN TABLE sweep_foreign_items (id bigint) SERVER sweep_loopback
OPTIONS (schema_name 'test', table_name 'items');

INSERT INTO sponsors VALUES (99);
INSERT INTO competitors VALUES (99, 99, 'Seed competitor');
