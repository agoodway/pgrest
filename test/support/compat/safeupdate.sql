-- Tables for the pg-safeupdate tests, ported from PostgREST's test/spec/fixtures/schema.sql
-- (v14.18, "Tables and functions to test the pg-safeupdate library"). Test harness only.
CREATE SCHEMA test;

CREATE TABLE test.safe_update_items (
  id INT PRIMARY KEY,
  name TEXT,
  observation TEXT
);

CREATE TABLE test.safe_delete_items (
  id INT PRIMARY KEY,
  name TEXT,
  observation TEXT
);

CREATE TABLE test.unsafe_update_items (
  id INT PRIMARY KEY,
  name TEXT,
  observation TEXT
);

CREATE TABLE test.unsafe_delete_items (
  id INT PRIMARY KEY,
  name TEXT,
  observation TEXT
);

INSERT INTO test.safe_update_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO test.safe_delete_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO test.unsafe_update_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
INSERT INTO test.unsafe_delete_items VALUES (1, 'item-1', 'a'), (2, 'item-2', 'b');
