# perl-orm-easy

In-database ORM for PostgreSQL

## The model

A database table is considered as a repository of objects of a single class. The classes can be inherited according to PostgreSQL object-relational approach.
Below "class" and "table" are synonyms, superclasses and subclasses are defined in terms of PostgreSQL table inheritance.

Each table has an `id` field of `idtype` type which is its primary key. The `idtype` type can be mapped to `int4`, `int8` (todo) or `uuid` (todo) database-wide.

This library provides easy object-level API to the database, with the following main functions:

- `mget`   (similar to SQL `SELECT`; returns an object list or a single object in a corner case)
- `save`   (similar to SQL `INSERT` or `UPDATE`; saves one new or existing object to the database)
- `delete` (similar to SQL `DELETE`; deletes one object)

and some additional ones:

- `msave` (similar to SQL `UPDATE` for multiple rows)
- `set_order` (numerate a set of objects in a given order)
- `set_order_parent` (same as `set_order` and also sets a `parent` field - useful for moving nodes in trees)

Additional  features:

- transaction support
- multiuser work with access control 
- logging historical records
- managing file storage
- referential constraints for inherited tables and arrays

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

Sometimes we want to reference database tables in the same way as table rows. To make it possible, orm-easy keeps a mapping from `idtype` identifiers to the symbolic names of the tables in a separate `orm.metadata` table.
PostgreSQL OIDs are not a solution for this because they are changed if the table (or the whole database) is deleted and recreated (or logically replicated, or dumped and reloaded). 
`orm.metadata` table has the following fields:

| Field             | Type   | Description                                                                                                                                            |
| ----------------- | ------ |------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`              | idtype | The identifier                                                                                                                                         |
| `name`            | text   | Full name of the table (with schema)                                                                                                                   |
| `public_readable` | bool   | Not null default false. If true, the read privilege (see below) is not checked by `mget`. It may mean that access is checked in ABAC-style (see below) |

### Access control; RBAC

orm-easy uses a parametric role-based access control model (RBAC) to manage user access to different operations in the database. 
Also, elements of attribute-based access control (ABAC) can be easily implemented with `mget` extensions, see below.

RBAC means that users are granted with roles, each of them being a set of privileges. 
Privileges are some elementary permissions which are checked during operations, 
while roles are sets of privileges sufficient for performing some kind of activity in the system, having sense from the business viewpoint.

With parametric RBAC, any user can be assigned a set of roles, each with optional parameters. A role may have zero, one or two parameters, each of them being 
a reference to some of the database objects. If a parameters has a NULL value, it means that the role is granted for all such objects. 
A role with parameters is below referred to as a "parametric role".

The role definition specifies the classes of objects the role can be bound to.

*Example:*

| Role                              | Number of parameters | Object classes    | Comment                                                                                                                                |
| --------------------------------- | -------------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| System administrator              | 0                    | None              | A classic non-parametric role                                                                                                          |
| Account manager of customer X     | 1                    | Customer          | A role is expected to be granted in relation to some definite Customer. A person managing 2 customers will be granted this role twice. |
| Expert on topic X in department Y | 2                    | Topic, Department | A person allowed to perform work on something (X) in department (Y).                                                                   |

When a parametric role is granted to some user, the values of all parameters should be specified, possibly as NULLs (which means 'all objects').

A parametric role is a set of privileges, some of them also can be parametric (or even should be parametric, because the role parameters should be mapped to the privilege parameters).

Examples of parametric privileges:

| Privilege                                               | Number of parameters | Object classes              | Comment                                          |
| ------------------------------------------------------- | -------------------- | --------------------------- | ------------------------------------------------ |
| Change user passwords                                   | 0                    | None                        | A classic non-parametric privilege               |
| Edit members of deparment X                             | 1                    | Department                  | So obvious, how to comment ?                     |
| Perform a workflow transition Y on issues of customer X | 2                    | Article category, Operation | E.g. in a service-desk or other BPMS system      |

A role is a set of privileges, in which the parameter values can have specified values, or be mapped to the role parameters.

*Example* (Role: Account manager for customer X):

| Privilege                                               | Parameters                 | Comment                                                                                                            |
| ------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Access to CRM application                               | None                       | All account managers use CRM system                                                                                |
| See customer X contacts                                 | X=role.X                   | Parameter is mapped from the role to the privilege                                                                 | 
| Perform a workflow transition Y on issues of customer X | X=role.X, Y="new=>work"    | One parameter is mapped from the role parameter, other has a fixed value (bound to a specific workflow transition) |
| Perform a workflow transition Y on issues of customer X | X=role.X, Y="work=>closed" | Another transition is allowed to the account manager in similar manner                                             |

The parametric RBAC system is managed by the following functions:

#### `auth_interface.check_privilege(user_id idtype, privilege_name text, object_ids text[] = NULL) RETURNS bool`

Checks if a user has this privilege for the specified set of parameters. Note that they are not `idtype[]`, but `text[]`. Each value of `object_ids` can be:

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

	SELECT auth_interface.check_privileges( user_id, '[
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

    { "list" : [ {object1}, {...}, .... ],
	  "n" : <total number>
	}

The list is usually a page of the whole selection, based on `page` and `pagesize` parameters. The total number is required to organize a paginated view.
If pagesize is zero, all objects will be returned.

The SQL query is formed on the base of the content of the `query` parameter, which is a JSONb object, described in the following sections.

### Options

#### Filtering by field values

For the query options with names equal to names of table fields, filtering by field values is performed, the exact form of SQL `WHERE` clause depends on the field type and value type, as specified in the following table:

| Field type              | Option value                | SQL fragment                              |
| ----------------------- | --------------------------- | ----------------------------------------- |
| `bool`                  | `true`                      | `field`                                   |
|                         | `false`                     | `NOT field`                               |
|                         | `NULL`                      | `field IS NULL`                           |
| `text`                  | `{ begins: str }`           | `field ~* '^value'`                       |
|                         | `{ contains: str }`         | `field ~* value`                          |
| `date`, `timestamp` etc | `[d1,d2]`                   | `field >= d1 AND field < d2`              |
|                         | `[d1, null]`                | `field >= d1`                             |
|                         | `[null, d2]`                | `field < d2`                              |
| scalar types except dates and times  | `scalar_value` | `field = scalar_value`                    |
|                         | `[..array..]`               | `field = ANY(array)`                      |
|                         | `{ any: v }`                | `field = ANY(v)`                          |
|                         | `{ not: array }`            | `NOT (field = ANY(array))`                |
|                         | `{ not_null: true }`        | `field IS NOT NULL`                       | 
| numeric types           | `non_numeric_value`         | If the field references another table, resolve it by name: `field = (SELECT id FROM ref.table WHERE name = non_numeric_value` |
| array                   | `[.....]`                   | `field && value`                          |
|                         | `{ contains_or_null: arr }` | `field && arr OR field IS NULL`           |
|                         | `{not: array }`             | `NOT (field && value) OR field IS NULL`   |
|                         | `{not: array }`             | `NOT (field && value) OR field IS NULL`   |
|                         | `NULL`                      | `field IS NULL`

Filters on several fields are joined with `AND`.

#### Special options

Special options are listed below:

| Option             | Value    | Description                     |
| ------------------ | -------- | ------------------------------- |
| `_order`           | `--expr` | `ORDER BY expr DESC NULLS LAST` |
|                    | `-expr`  | `ORDER BY expr DESC`            |
|                    | `expr`   | `ORDER BY expr`                 |
|                    | `'specified'`       | Only if selecting by array of id: return objects in the same order as their identifiers are listed in the array |
|                    | `[array of expr]`   | ORDER BY several fields, above variants apply to each of them |
| `_fields`          | `[field_list]`      | fields to select from the table. If not specified, all fields will be selected. |
| `_exclude_fields`  | `[field_list]`      | fields to exclude from the selection.   |
| `_group`           | `[field_list]`      | `GROUP BY <field_list>` |
| `_aggr`            | `[aggregates list]` | currently only one aggregate is supported: `count` |
| `with_can_update`  | `true`              | adds result of `schema.can_update_<table_name>(user_id, object_id::text, NULL::jsonb)` user-defined function |
| `with_permissions` | `true`              | same as `with_can_update`, and also add result of `schema.can_delete_<table_name>(user_id, object_id::text)` user-defined function |
| `__subclasses`     | `true`              | perform UNION of all the subclasses tables instead of querying this table, to get all the fields of them. |
| `__root`           | node identifier     | perform a recursive query (supposed that the table represents a tree linked with `parent` field). |
| `__tree`           | `'ordered'`         | sort the tree on the node positions (supposed that the child nodes within a single parent can be ordered by `pos` field). |
| `without_count`    | `true`              | do not return total number of the objects. |


### Examples

User 128 selects persons with specified identifiers in the specified order.

    SELECT auth_interface.mget('crm', 'person', 128, 1, null, '{"id": [ 15,16,17], "_order" : "specified" , "without_count": true}');

User 129 selects 10 first persons with last_names starting with 'Stone' born in 1992 sorted by their birthdays.

	SELECT auth_interface.mget('crm', 'person', 129, 1, 10, '{"last_name": { "begins" : "Stone"}, "birthday": ["1992-01-01", "1993-01-01"]}');

User 130 reads 3rd page of the news on computers.

	SELECT auth_interface.mget('cms', 'news', 130, 3, 20, '{"status" : "published", "_order": "-publication_date", "topic": "computers"}');

### Extending mget

#### query_&lt;tablename&gt; functions (query preprocessors)

User-defined query preprocessors can be used to extend the query construction features. 
Such function should be defined as 

    <schema>.query_<table_name> (user_id idtype, internal_data jsonb, query jsonb) RETURNS jsonb

The function accepts the current `internal_data` structure, modifies it and returns the new value. This structure represents the current state of the query preparation.
`query` is the parameter of mget which is translated to the query function.

Query preprocessors for superclasses are called after the query preprocessor of the current class.

The `internal_data` structure has the following fields: 

* wheres -- array of where quals to be joined with `AND`
* joins  -- array of `'JOIN table ON .....'` clauses 
* left_joins -- array of `'LEFT JOIN table ON .....'` clauses
* bind    -- array of bound values
* types   -- array of bound value types

The main table in the query has an `m` alias.

*Example* of a function adding full text search function for a `cms.news` table (supposing it has a `ts_vector` field).

    CREATE FUNCTION cms.query_news (user_id idtype, internal_data jsonb, query jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
	DECLARE n int;
    BEGIN
      IF query ? 'search' THEN 
		n = jsonb_array_length(internal_data->'bind')+1;
		internal_data = jsonb_set(internal_data, ARRAY['wheres',  '1000000' ], to_jsonb(format('m.ts_vector && @@ to_tsquery($%s::text)', n)));
		internal_data = jsonb_set(internal_data, ARRAY['bind',    '1000000' ], query->'search');
		internal_data = jsonb_set(internal_data, ARRAY['types',   '1000000' ], to_jsonb('text'));
	  END IF;
      RETURN internal_data;
    END;
    $$;

	SELECT auth_interface.tsearch('cms', 'news', 131, 1, 20, '{"status" : "published", "search": "Metanoia"}');


#### postquery_&lt;tablename&gt; functions (query postprocessors)

User-defined Postquery functions can be used to post-process query results. 
Such function should be defined as 

    <schema>.postquery_<table_name> (user_id idtype, result jsonb, query jsonb) RETURNS jsonb

Query postprocessors for superclasses are called after the query postprocessor of the current class.


The `user_id` and `query` parameters are same as for the parent `mget` function; `result` is the array of objects to be returned by `mget`.
The return value of a postquery function should be the modified array of objects or NULL if no modifications are required.

## save

Saves an object into the database (inserts a new object or updates an existing one)

`orm_interface.save(schema text, tablename text, id text,  user_id idtype, object jsonb, context jsonb) RETURNS json_pair`

### Options

#### `schema`, `tablename`

Target table of the operation

#### `id`

`id` is the object identifier. If `id` is a number or valid uuid (not yet supported) then `save` attempts to UPDATE the object with such identifier. 
In other cases (`id` is NULL or a temporary text identifier (see below)) `save` will perform an INSERT. 
The object identifier of the new object is taken from `object` JSON or, if not defined, automatically computed from `orm.id_seq` sequence or UUID generator.

#### `user_id`

The current user identifier

### `object`

The object field names and their values to be saved.

### `context`

A JSONB object for communications between several `save`s in a transaction or a script (see TRANSACTION SUPPORT below).

### Return value

Return value is a row of two JSONs: a saved object and a modified `context`.

### Permissions checking

If a `can_insert_<tablename>(user_id idtype, id text, data jsonb)` or `can_update_<tablename>(user_id idtype, id text, data jsonb)` user-defined function exists, 
this function will be called before INSERT or UPDATE respectively. These permission checker functions should return true if the operation is allowed.
If the action is not allowed, the cheker may return false or throw an informative exception.

If the permission checker is not defined, orm-easy tries to call its internal chekers `orm.can_insert_object` or `orm.can_update_object` respectively. 
There functions, defined in `can_object.sql`, check presense of `create_object` or `edit_object` privileges (see RBAC above) for at least one of the table and its superclass tables. 

### Referencing by name

If an object field contains a reference to other table having a `name` field, orm-easy allows referencing such table by name, not by `id`. 
This works only if a corresponding referencial constraint exists in the database.

Example:

	INSERT INTO status (id,name) VALUES (1, 'done');
	CREATE TABLE public.order (
	    id     idtype PRIMARY KEY,
	    status idtype REFERENCES status(id)
	);
	orm_interface.save('public', 'order', 
					   12345678, -- order id
					   101, -- user_id 
					   '{ "status" : "done", /* a reference by name */ 
					   ....}', '{}'
    );
    
### Special values

For some types of fields, special values are allowed:

* For all field types, an undefined value will become NULL. 
* For numeric fields, `me` will be replaced with current user id.
* For date and time fields, `now` will be replaced with current date or time.
* For boolean fields, any value which is equal to `true` in Perl sense, will be true
* Updating numeric array fields can be done in add&delete style, like in the example below.

Example:

	{ 
		"array_field" : {
			"add"    :  [1,2,3], /* can be array or scalar here */
			"delete" :  [3,4,5]  /* and here */
		}
	}

### Extending save

#### presave_&lt;tablename&gt; functions

Presave handler is a user-defined called before saving an object to perform some user-defined field computations and additional checks. 
Such handler should be defined as:

	CREATE FUNCTION <schema>.presave_<tablename>(user_id idtype, id idtype, op text, old_data jsonb, new_data jsonb, original_schema_name text, original_table_name text) RETURNS jsonb

The difference with database BEFORE INSERT or BEFORE UPDATE triggers is:

* presave handlers are not called for manually run INSERTs and UPDATEs.
* presave handlers are called for all superclass tables in the inheritance tree of the current table in-depth.

The parameters are:

* `user_id`: The current user identifier
* `id`: The object identifier (if INSERT, it is the computed identifer)
* `old_data`: The content of the object as a JSONB object (empty for INSERTs) before operation.
* `new_data`: The updated fields as a JSONB object
* `original_schema_name`: The name of the schema for each the `save` operation was called (may differ from the current handler schema in the case of table inheritance).
* `original_table_name`: The name of the table for each the `save` operation was called (may differ from the current handler `tablename` in the case of table inheritance).

Presave handler should return the `new_data` object, modified or not.

#### postsave_&lt;tablename&gt; functions

Postsave handler is a user-defined function is called after saving an object.

It is completely similar to the presave handler.

## delete

Deletes an object from database.

`orm_interface.delete(schema text, tablename text,  id text, user_id idtype, context jsonb) RETURNS jsonb`

### Options

#### `schema`, `tablename`

Target table of the operation

#### `id`

`id` is the object identifier. 

#### `user_id`

The current user identifier

### `context`

A JSONB object for communications between several `save`s and `delete`s in a transaction or a script (see TRANSACTION SUPPORT below).

### Return value

Return value is a row of two JSONs: a saved object and a modified `context`.

### Permissions checking

If a `can_delete_<tablename>(user_id idtype, id text, data jsonb)` user-defined function exists, 
this function will be called before INSERT or UPDATE respectively. These permission checker functions should return true if the operation is allowed.
If the action is not allowed, the cheker may return false or throw an informative exception.

If the permission checker is not defined, orm-easy tries to call its internal chekers `orm.can_delete_object` respectively. 
There functions, defined in `can_object.sql`, check presense of `create_object` or `edit_object` privileges (see RBAC above) for at least one of the table and its superclass tables. 

### Extending delete

#### predelete_&lt;tablename&gt; functions

Predelete handler is a user-defined function called before deleting an object to perform some user-defined field computations, cascade deletions and additional checks. 
Such handler should be defined as:

	CREATE FUNCTION <schema>.predelete_<tablename>(user_id idtype, id idtype, op text, old_data jsonb, original_schema_name text, original_table_name text) RETURNS jsonb

The difference with database BEFORE DELETE triggers is:

* predelete handlers are not called for manually run DELETEs.
* predelete handlers are called for all superclass tables in the inheritance tree of the current table in-depth.

The parameters are:

* `user_id`: The current user identifier
* `id`: The object identifier
* `old_data`: The content of the object as a JSONB object before operation 
* `original_schema_name`: The name of the schema for each the `save` operation was called (may differ from the current handler schema in the case of table inheritance).
* `original_table_name`: The name of the table for each the `save` operation was called (may differ from the current handler `tablename` in the case of table inheritance).

Predelete handler return value is not yet processed.

#### postdelete_&lt;tablename&gt; functions

Postdelete handler is a user-defined function is called after saving an object.

It is completely similar to the predelete handler.


## msave

Saves multiple objects in one call by saving a set of objects found by `mget`.

	`orm_interface.mget(schema text, tablename text, user_id idtype, page int, pagesize int, query jsonb, data jsonb, context jsonb) RETURNS jsonb`
	
Performs `save` with given `data` on each object in the page which would be returned by `mget` with given corresponding parameters.

## set\_order

    orm_interface.set_order (schema text, tablename text, ids jsonb, field text, user_id idtype, context jsonb)

## Other features

### Global unique ids

We require each table to have a primary key `id`. 
A strong recommendation is to provide all the `id`s from a single sequence to make them unique between tables. 
`save` function implements this policy by getting the new object identifiers from `orm.id_seq` sequence.

### Temporary identifiers

Multiple `save` and `delete` functions can be run sequentially in a transaction or script. orm-easy provides tools to transport some information context from one to another `save` call. 
A frequent use case is a sequence of `save`s with cross-references between object being saved. 
The problem is that when the first object is not yet created, its `id` is unknown and we cannot prepack all the `save` sequence in advance. 
orm-easy allows to solve this problem by using temporary text identifiers which can be used where integer identifiers are yet unknown. 

Example:

	orm_interface.save('public', 'order', 
					   'new_order', -- temporary id!
					   101, -- user_id 
					   '{....}', '{}'
    );
    orm_interface.save('public', 'order_item', 
					   NULL,/* id */
					   101, -- user_id 
					   '{"order" : "new_order",  /* a reference to a temporary id */
					     ....
					    }', '{}');

This allows to prepack a transaction with creating several connected objects without waiting for the first operation or reserving `id` in advance.

Note that resolving temporary identifiers is done after resolving references by name (see 'referencing by name' in `save` description above). Avoid ambiguity.


### File storage management

To do.

### Working with trees

To do.


### Referential constraints for inherited tables

In PostgreSQL, you can inherit tables so that their fields are inherited, but foreign keys to this fields are not inherited. 
To ensure referential integrity in the sense of referencing a system of inherited tables, orm-easy provides a set of predefined triggers and a metadata table.

An example: 

	CREATE TABLE schema1.some_base_class ( ... );
	CREATE TABLE schema1.first_subclass ( ... ) INHERITS (schema1.some_base_class);
	CREATE TABLE schema1.other_subclass ( ... ) INHERITS (schema1.some_base_class);
 
	CREATE TABLE schema2.some_referencing_class (
	   ....
	   some_ref idtype, -- you cannot write: REFERENCES schema1.some_base_class(id)
	);
 
To ensure referencial integrity (like `some_ref` field references `id` in a subclass of `some_base_class`), create a metadata record:

	INSERT INTO orm.abstract_foreign_key('schema2','some_referencing_class', 'some_ref', 'schema1','some_base_class');
 
This will create triggers which are necessary to check the integrity.

Attention: After adding / removing inherited tables the metadata record should be recreated. Unfortunately, PostgreSQL provides no means to process this automatically.

### Referential constraints for arrays 

In PostgreSQL, you cannot put referential constraints on arrays. orm-easy allows to make an array of references with integrity checks.

An example:

	CREATE TABLE schema1.t1 ( .... );
	CREATE TABLE schema2.t2 ( 
	 ....
	 some_ref idtype[], -- you cannot write: REFERENCES schema1.t1(id)
	);
 
To ensure referencial integrity (like `some_ref` is an array of references to `id` in `t1` table), create a metadata record:
 
	INSERT INTO orm.array_foreign_key('schema2','t2', 'some_ref', 'schema1','t1');


## Tables

To do.

## Installation to your database

orm-easy contains several installation scripts which create all necessary objects in the database. 

`sql/00_idtype_int4.sql` – defines `idtype` as `int4`

`sql/00_idtype_int8.sql` – defines `idtype` as `int8`

`sql/00_idtype_uuid.sql` – defines `idtype` as `uuid`

Run only one of the tree above scripts before any other one.

`sql/00_plperl.sql` – creates PL/Perl with `bool_plperl` and `jsonb_plperl` extensions. Needs to be ran before creating any orm-easy functions.

`sql/id_seq.sql` – creates the `id_seq` sequence for the automatic provision of numeric identifiers for the database objects.

`sql/schema.sql` – creates the orm-easy schemas `orm_interface` for the API functions and `orm` for the internal data and functions.

`sql/tables.sql` – creates the orm-easy tables

`sql/functions.sql` – defines some internal orm-easy functions

`sql/api_functions.sql` – defines the main API functions: `mget`, `save`, `delete`, `set_order`.

`sql/rbac_tables.sql` – defines tables used for RBAC (roles, privileges and relationships between them).

`sql/rbac_functions.sql` – defines RBAC functions

`sql/can_object.sql` – defines functions to check object permissions

`sql/store_file.sql` – defines functions for file storage

`sql/presave__traceable.sql` – defines presave handler for `_traceable` class. Also can be used as an example.

`sql/query__traceable.sql` – defines query preprocessor for `_traceable` class. Also can be used as an example.

`sql/foreign_keys.sql` -- defines tools to enable array and abstract foreign keys.




