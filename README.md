# perl-orm-easy

In-database ORM for PostgreSQL

## The model

A database table is considered as a repository of objects of a single class. The classes can be inherited according to PostgreSQL object-relational approach.
Below "class" and "table" are synonyms, superclasses and subclasses are defined by means of PostgreSQL table inheritance.

Each table has an `id` field of `idtype` type which is its primary key. The `idtype` type can be mapped to `int4`, `int8` (todo) or `uuid` (todo) database-wide.

This library provides easy object-level API to the database, consisting of the following functions:

- mget   (similar to SQL `SELECT`; returns an object list or a single object in a corner case)
- save   (similar to SQL `INSERT` or `UPDATE`; saves a new or existing object to the database)
- delete (similar to SQL `DELETE`; deletes an object)

### Multiuser work

Each action is done on behalf of some application level user, identified by its `id` of `idtype`. The user authentication is expected to be somewhere in the application
beyond orm-easy. Nevertheless, orm-easy has tools to check the user permissions and to record their activity.

### History log

Some of the object classes in the database may be 'traceable'. It means that they store their creation and last modification time and author, and the historical versions
are archived to a special table named `history_log` in each schema.

To make a table traceable, inherit it from `orm._traceable` and call  `make_triggers`:

    CREATE TABLE ... ( ) INHERITS(orm._traceable); -- Creates the additional fields
    SELECT orm.make_triggers (schema, tablename);  -- Creates triggers

The `history_log` table should be created manually in each schema as:

    CREATE TABLE my_schema.history_log (...) INHERITS (orm.history_log);

or

    CREATE TABLE my_schema.history_log (
      relname  text,        -- table name
      id       idtype,      -- object id
      "time"   timestamptz, -- save operation time
      "user"   idtype,      -- user who saved the objet
      data     jsonb        -- the object version content
    );

### Table identification

To reference a table, in some cases an `idtype` identifier is preferable over its symbolic name. PostgreSQL OIDs are not a solution for this because of they change
if the table (or the whole database) is deleted and recreated. So, orm-easy defines an orm.metadata table with the following fields:

| Field           | Type   | Description                                                                                                                                        |
| --------------- | ------ |--------------------------------------------------------------------------------------------------------------------------------------------------- |
| id              | idtype | The identifier                                                                                                                                     |
| name            | text   | Full name of the table (with schema)                                                                                                               |
| public_readable | bool   | Not null default false. If true, read privilege (see below) is not checked by `mget`. It may mean that access is checked in ABAC-style (see below) |

### Access control; RBAC

orm-easy allows use a parametric role based access control model (RBAC) to manage user access to different operations in the database. 
Also, elements of attribute-based access control (ABAC) can be easily implemented with `mget` extensions, see below.

RBAC means that users are granted with roles, each of them being a set of privileges. 
Privileges are some elementary permissions which are checked during operations, 
while roles are sets of privileges sufficient for performing some kind of activity in the system, having sense from the business viewpoint.

With parametric RBAC, any user can be assigned a set of roles, each with optional parameters. A role may have zero, one or two parameters, each of them being 
a reference to some of the database objects. If a parameters has a NULL value, it means that the role is granted for all such objects. 
A role with parameters is below referred to as a "parametric role".

The role definition specifies the classes of the objects the role can be bound to.
Real world examples:

| Role                              | Number of parameters | Object classes    | Comment                                                                                                                                 |
| --------------------------------- | -------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| System administrator              | 0                    | None              | A classic non-parametric role                                                                                                        |
| Account manager of customer X     | 1                    | Customer          | A role is expected to be granted in relation to some definite Customer. A person managing 2 customers will be given this role twice. |
| Expert on topic X in department Y | 2                    | Topic, Department | A person performing work on something (X) in department (Y).                                                                         |

When a parametric role is granted to some user, the values of all parameters should be specified, possibly as NULLs.

A parametric role is a set of privileges, which also can be parametric (or even should be parametric, because the role parameters are mapped to the privilege parameters).

Examples of parametric privileges:

| Privilege                                               | Number of parameters | Object classes              | Comment                                          |
| ------------------------------------------------------- | -------------------- | --------------------------- | ------------------------------------------------ |
| Change user passwords                                   | 0                    | None                        | A classic non-parametric privilege               |
| Edit members of deparment X                             | 1                    | Department                  | So obvious, how to comment ?                     |
| Perform a workflow transition Y on issues of customer X | 2                    | Article category, Operation | E.g. in a service-desk like or other BPMS system |

A role is a set of privileges, in which the parameter values can have specified values, or be mapped to the role parameters.

Example (Role: Account manager for customer X):

| Privilege                                               | Parameters                 | Comment                                                                                                  |
| ------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------- |
| Access to CRM application                               | None                       | All account managers use CRM system                                                                      |
| See customer X contacts                                 | X=role.X                   | Parameter is mapped from the role to the privilege                                                       | 
| Perform a workflow transition Y on issues of customer X | X=role X, Y="new=>work"    | One parameter is mapped from the role, other has a fixed value (bound to a specific workflow transition) |
| Perform a workflow transition Y on issues of customer X | X=role X, Y="work=>closed" | Another transition is also allowed for the account manager                                               |

The parametric RBAC system is managed by the following functions:

#### `auth_interface.check_privilege(user_id idtype, privilege_name text, object_ids text[] = NULL) RETURNS bool`

Checks if user has this privilege for the specified set of parameters. Note that they are not `idtype[]`, but `text[]`. Each value of `object_ids` can be:

* an id of some object in the database;
*  `"__all__"` which means that this privilege is checked for all objects of the corresponding class;
* a string which is treated as a symbolic name of some object of the corresponding class (i.e. value of its unique `name` field).

#### `auth_interface.get_privilege_objects(user_id idtype, privilege_name text) RETURNS table (objects idtype[])`

Returns the value sets of the parameters of the specified privilege which are currently granted to the specified user.

#### `auth_interface.check_privileges (user_id idtype, privileges json) RETURNS SETOF auth_interface.checked_privileges`

Checks several privileges at one time (see `check_privilege` before). 
Here the `auth_interface.checked_privileges` is defined as a composite type `(privilege_name text, object_ids text[])`. 

The `privileges` parameter is a JSON array, elements of which can be:
* a text scalar containing a privilege name
* or an array, first element is a privilege name, and the second is an array of the privilege parameters (see `auth_interface.check_privilege`)

Example:

	SELECT auth_interface.checked_privileges( user_id, '[
		"Access to CRM application",
		["Perform a workflow transition Y on issues of customer X", [ 14341343, 3423242 ]]
	]'::json );

#### `add_role(user_id idtype, grantee_id idtype, role_name text, objects_ids idtype[], expires_at timestamptz = NULL)`

The user `user_id` grants a role `role_name` to a user `grantee_id` with optional parameters and expiration date. 
Note that the permissison for this operation will be checked by calling a boolean function `auth.can_add_role_<role_name> (user_id, grantee_id, object_ids)`.
Such function must exist.

#### `auth_interface.get_roles_addable(user_id idtype, grantee_id idtype) RETURNS json`

Returns a JSON array of roles which `user_id` can grant to `grantee_id`.

## mget

Gets a list of objects or a page of a long list.

`orm_interface.mget(schema text, tablename text, user_id idtype, page int, pagesize int, query jsonb) RETURNS jsonb`

The objects are selected from a table specified by schema and tablename. 

First of all, access is checked: the user (`user_id`) should have privilege `view_objects` 
for this table or one of its superclasses.

Then the query is formed and executed.

The return value is a JSONb of the following structure:

    { "list" : [ {...}, {...}, .... ],
	  "n" : <total number>
	}

The list is usually a page of the whole selection, acccoring to `page` and `pagesize` parameters. The total number is required to organize page-by page view.
If pagesize is zero, all objects will be returned.

The SQL query is formed due to content of the `query` parameter, which is a JSONb object, described in the following sections.

### Options

#### Filtering by field values

For the query options with names equal to names of table fields, filtering by field values is performed, the exact form of SQL `WHERE` clause depends on the field type and value type, as specified in the following table:

| Field type        | Option value                | SQL fragment                              |
| ----------------- | --------------------------- | ----------------------------------------- |
| `date`            | `[d1,d2]`                   | `field >= d1 AND field < d2`              |
|                   | `[d1, null]`                | `field >= d1`                             |
|                   | `[null, d2]`                | `field < d2`                              |
| array             | `[.....]`                   | `field && value`                          |
|                   | `{ contains_or_null: arr }` | `field && arr OR field IS NULL`           |
|                   | `{not: array }`             | `NOT (field && value) OR field IS NULL`   |
|                   | `{not: array }`             | `NOT (field && value) OR field IS NULL`   |
|                   | `NULL`                      | `field IS NULL`
| scalar types      | `[.....]`                   | `field = ANY(value)`                      |
|                   | `scalar_value`              | `field = scalar_value`                    |
|                   | `{ any: v }`                | `field = ANY(v)`                          |
|                   | `{ not: array }`            | `NOT (field = ANY(array))`                |
|                   | `{ not_null: true }`        | `field IS NOT NULL`                       | 
| `text`            | `{ begins: str }`           | `field ~* '^value'`                       |
|                   | `{ contains: str }`         | `field ~* value`                          |
| numeric types     | `non_numeric_value`         | If the field references another table, resolve it by name: `field = (SELECT id FROM ref.table WHERE name = non_numeric_value` |
| `bool`            | `true`                      | `field`                                   |
|                   | `false`                     | `NOT field`                               |
|                   | `NULL`                      | `field IS NULL`                           |


Filters on several fields are joined with `AND`.

#### Special options

Special options are listed below:

| Option             | Value    | Description                     |
| ------------------ | -------- | ------------------------------- |
| `_order`           | `--expr` | `ORDER BY expr DESC NULLS LAST` |
|                    | `-expr`  | `ORDER BY expr DESC`            |
|                    | `expr`   | `ORDER BY expr`                 |
|                    | `'specified'`       | Only if selecting by array of id: return objects in the same order as there identifiers are specified in the query. |
|                    | '[array of expr]'   | ORDER BY several fields, above variants apply to each of them |
| `_fields`          | `[field_list]`      | fields to select from the table. If not specified, all fields will be selected. |
| `_exclude_fields`  | `[field_list]`      | fields to exclude from the selection from the table.   |
| `_group`           | `[field_list]`      | `GROUP BY <field_list>` |
| `_aggr`            | `[aggregates list]` | currently only one aggregate is supported: `count` |
| `with_can_update`  | `true`              | adds result of `schema.can_update_<table_name>(user_id, object_id::text, NULL::jsonb)` user-defined function |
| `with_permissions` | `true`              | same as `with_can_update`, and also add result of `schema.can_delete_<table_name>(user_id, object_id::text)` user-defined function |
| `__subclasses`     | `true`              | perform UNION of all the subclasses tables instead of querying this table, to get all the fields of them. |
| `__root`           | node identifier     | perform a recursive query (supposed that the table represents a tree linked with `parent` field). |
| `__tree`           | `'ordered'`         | sort the tree on the node positions (supposed that the child nodes of a same parent are sorted by `pos` field). |
| `without_count`    | `true`              | do not return total number of the objects. |


### Examples

User 128 selects persons with specified identifiers in the specified order.

    SELECT auth_interface.mget('crm', 'person', 128, 1, null, '{"id": [ 15,16,17], "_order" : "specified" , "without_count": true}');

User 129 selects 10 first persons with last_names starting with 'Stone' born in 1992 sorted by their birthdays.

	SELECT auth_interface.mget('crm', 'person', 129, 1, 10, '{"last_name": { "begins" : "Stone"}, "birthday": ["1992-01-01", "1993-01-01"]}');

User 130 reads 3rd page of the news on computers.

	SELECT auth_interface.mget('cms', 'news', 130, 3, 20, '{"status" : "published", "_order": "-publication_date", "topic": "computers"}');

### Extending mget

#### query_<tablename> functions

User-defined Query functions can be used to extend the query construction possibilities. 
Such function should be defined as 

    schema.query_<table_name> (user_id idtype, internal_data jsonb, query jsonb) RETURNS jsonb

The function accepts the current `internal_data` structure, modifies it and returns the new value. This structure represents the current state of the query preparation.
`query` is the parameter of mget which is translated to the query function.

The `internal_data` structure has the following fields: 

* wheres -- array of where quals to be joined with `AND`
* joins  -- array of `'JOIN table ON .....'` clauses 
* left_joins -- array of `'LEFT JOIN table ON .....'` clauses
* bind    -- array of bound values
* types   -- array of bound value types

The main table in the query has an `m` alias.

Example of function adding text search capability to `crm.person` table (supposing it has a `ts_vector` field).

    CREATE FUNCTION crm.query_person (user_id idtype, internal_data jsonb, query jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
	DEFINE n int;
    BEGIN
      IF query ? 'search' THEN 
		n = json_array_length(internal_data->>'bind');
		internal_data = jsonb_set(internal_data, ARRAY['wheres',  1000000 ], format('m.ts_vector && @@ to_tsquery($%s::text))', n);
		internal_data = jsonb_set(internal_data, ARRAY['bind',    1000000 ], query->>'search';
		internal_data = jsonb_set(internal_data, ARRAY['types',   1000000 ], 'text';
	  END IF;
      RETURN internal_data;
    END;
    $$;


#### postquery_<tablename> functions

## save

If new objects come without identifiers, they are automatically numbered using `orm.id_seq` sequence.

### Options

### Extending save

#### presave_<tablename> functions

#### postsave_<tablename> functions

## delete

### Options

### Extending delete

#### predelete_<tablename> functions

#### postdelete_<tablename> functions

## set\_order

    orm_interface.set_order (schema text, tablename text, ids jsonb, field text, user_id idtype, context jsonb)

## Transaction support

 

## File storage

## Other functions

## Tables

To do.

## Installation to your database

orm-easy contains several installation scripts which create all necessary objects in the database. 

`sql/00_idtype_int4.sql` – defines `idtype` as `int4`
`sql/00_idtype_int8.sql` – defines `idtype` as `int8`
`sql/00_idtype_uuid.sql` – defines `idtype` as `uuid`

Run only one of these scripts before any other one.

`sql/00_plperl.sql` – creates PL/Perl with `bool_plperl` and `jsonb_plperl` extensions. Needs to be ran before creating any orm-easy functions.
`sql/tables.sql` – creates the orm-easy tables


`sql/functions.sql` – defines some internal orm-easy functions
`sql/api_functions.sql` – defines the main API functions: `mget`, `save`, `delete`, `set_order`.

`sql/rbac_tables.sql` – defines tables used for RBAC (roles, privileges and relationships between them).
`sql/rbac_functions.sql` – defines RBAC functions






