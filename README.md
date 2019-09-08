# PostgreSQL SQL/MED DATALINK extension

## Disclaimer

This extension is a proof of concept for implementing DATALINK in PostgreSQL,
it must not be used in production until an official release will be published.
Expect changes in the implementation and behaviors before the official release.

The documentation is at its early stage, for detailled information look
at the presentation at [PgConf Asia 2019 conference](http://www.pgconf.asia)

## Installation

The Datalink extension requires the `uuid-ossp` and the [uri](https://github.com/darold/uri) extensions.
 
In order to install the Datalink extension download latest developement sources
from [GitHub](https://github.com/darold/datalink) and use the following command
to build and install the extension. `pg_config` must be in found from your PATH
environment variable.

        make
        sudo make install

To test the extension run, it is required that the user running the script be
PostgreSQL superuser and able to execute commands using sudo:

        cd test/
	sh dl_test.sh

To use the extension in your database execute:

        CREATE EXTENSION uri;

The default values for GUC related to the DATALINK extension are forced to:

	datalink.dl_naptime = 10
	datalink.dl_base_directory = '/tmp/test_datalink'
	datalink.dl_token_path = '/tmp/test_datalink/pg_dltoken'
	datalink.dl_token_expiry = 60
	datalink.dl_keep_max_copies = 5

This is the one I use for the proof of concept, feel free to adjust them in
datalink.h before compiling. This is not possible to change them from the
configuration file for the moment but it will be possible as soon as the
extension move to beta stage.

## Description

DATALINK is an SQL data type that allows to store a reference to a file that
is external to the database system.

SQL/MED allows a variety of attributes to be specified for DATALINK columns.
They are used to defined how the database system controls the file. This can
be from no control at all (the file does not even have to exist) to full
control, where removal of the datalink value from the database leads to a
deletion of the physical file.

DATALINKs supports two permission modes to read and write datalinks, namely

  * READ/WRITE PERMISSION FS (Controlled by the File System)
  * READ/WRITE PERMISSION DB (Controlled by the Database system)

There is a third mode WRITE PERMISSION BLOCKED that provides data recovery
functionality for an SQL-mediated file (WRITE PERMISSION DB), as long as the
RECOVERY option is specified as YES.

This third option mean that a user cannot update the file while the file is
referenced in a DATALINK column. Updating the content of a file that in this
mode requires three distinct steps:

	1. Unlinking the file
	2. Modifying the file
	3. Re-linking the file

The extension use a Copy-On-Write mechanism so this mode is always used in
term that it never modify a file in place.

### PERMISSION FS

When READ or WRITE PERMISSION FS is specified, the system that control the
DATALINK functionality allows user to update a file while the file remains
linked to the database. This mode does not provide consistency and file data
recovery. Which means that in case of crashes or a user needs to restore the
database, there is no backup data to recover. In cases of transaction failure,
this may cause inconsistency between the file data and the database data.

In this mode, read/write access privileges are determined by the file system
permissions assigned to the file. PostgreSQL only allow access to external
file through the user running the database system, mostly the postgres user.

For all these reasons it is not recommended to used this mode. Although the
DATALINK extension provide this mode, this is only through the postgres user.

READ/WRITE PERMISSION FS does not support a token-based access model like the
one provided with READ/WRITE PERMISSION DB/ADMIN.

When READ or WRITE PERMISSION DB is specified, the system that control the
DATALINK functionality allows user to update a file while the file remains

### PERMISSION DB/ADMIN

When READ PERMISSION DB is specified, this is the database server that control
which users are authorized to access the file. Writing is controlled by the
Database system if WRITE PERMISSION ADMIN option is set. 

These options can be followed by either the keywords REQUIRING TOKEN FOR UPDATE
or the keywords NOT REQUIRING TOKEN FOR UPDATE.

* "REQUIRING TOKEN FOR UPDATE" indicates that the token, which was included
in the file reference returned to the user when he requested an access to the
file, is needed to update the DATALINK value in question.
* "NOT REQUIRING TOKEN FOR UPDATE" indicates that this token is not
needed to update the DATALINK value.

"NOT TOKEN FOR UPDATE" does not allow concurrency level at Database side, it
must be handled by the application. Although it is implemented in the extension
it is recommended to always used "REQUIRING TOKEN FOR UPDATE" by this way file
data recovery can be supported in an implementation-dependent way, as long as
the RECOVERY option is set to YES.

## DATALINK functions

### DLVALUE ( data-location , directory-base , comment )

The DLVALUE function returns a DATALINK value. When the function is in a
VALUES clause in an INSERT statement, it creates a link to an external file.

If only a comment is specified, the data-location is a zero-length string and
the DATALINK value is created with no file link.

**data-location**

Uri data type containing an URL value or a path.

**directory-base**

An optional text expression that specifies the link base directory of the
DATALINK value. The valid value are 'URL', 'FILE' and any other value
representing a directory that is registered in pg_catalog.pg_datalink_bases
table.

**comment-string**

An optional text value that provides a comment or additional information.

The result of the function is a DATALINK value. If the data-location is
null, the result is the null value.

**Examples**

Insert a DATALINK URL using the default base directory:

	INSERT INTO dl_example VALUES( 1, DLVALUE('http://www.darold.net/', NULL, 'Web site');

Insert a local path DATALINK:

	INSERT INTO dl_example VALUES( 1, DLVALUE('/var/lib/pgsql/files/info.dat', 'FILE', 'Local path');

Insert a NULL DATALINK:

	INSERT INTO dl_example VALUES( 1, DLVALUE(NULL, 'FILE', 'Return null');

Insert an empty URL:

	INSERT INTO dl_example VALUES( 1, DLVALUE('', 'URL', 'Empty uri value') );

Insert just a comment with empty uri:

	INSERT INTO dl_example VALUES( 1, DLVALUE('Empty uri value') );


### DLVALUE ( datalink, data-location , directory-base-string , comment-string )

The DLVALUE function returns a DATALINK value. In this form the function is to
be used on the right side of a SET clause in an UPDATE statement, it replace
the link to an external file.

Same description as DLVALUE for INSERT statement except first parameter that
is the DATALINK column that has to be updated. In future implementation this
parameter will be removed in respect to the standard SQL as the value must be
taken from the left operand of the UPDATE statement. This mean that in a short
term there will be just one version of the DLVALUE() function, the same as the
one use with INSERT statement.

The result of the function is a DATALINK value. If the data-location is
null, the result is the null value.

**Examples**

Update a DATALINK URL:

	UPDATE dl_example SET efile = DLVALUE('http://www.darold.net/', MyWebSite', 'Web site') WHERE id = 1;


### DLCOMMENT ( datalink )

The DLCOMMENT function returns the comment value of a DATALINK record.
The argument must be an expression that results in a DATALINK type value.

The result of the function is of type text and can be null if the value is null.

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://pgcluu.darold.net/index.html','URL','Main page of pgCluu site')

then call to the function on that DATALINK will return:

	SELECT DLCOMMENT(EFILE)

will return the value:

	Main page of pgCluu site


### DLLINKTYPE ( datalink )

The DLLINKTYPE function returns the link type value from a DATALINK. The
argument must be a DATALINK data type.

The result of the function is of type text and can be null if the value is null.

The link type value is either FILE, URL or the base directory of the DATALINK

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://pgcluu.darold.net/index.html','URL','Main page of pgCluu site')
or
	DLVALUE('http://pgcluu.darold.net/index.html', NULL,'Main page of pgCluu site')

then call to the function on that DATALINK will return:

	SELECT DLLINKTYPE(EFILE)

will return the value:

	URL

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('/var/log/postgresql/postgresql-11.log','FILE','PostgreSQL log file')
or
	DLVALUE('/var/log/postgresql/postgresql-11.log',NULL,'PostgreSQL log file')

then call to the function on that DATALINK will return:

	SELECT DLLINKTYPE(EFILE)

will return the value:

	FILE

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('/tmp/test_datalink/jatfttd.txt','test_directory','Just a temporary file to test directory')

then call to the function on that DATALINK will return:

	SELECT DLLINKTYPE(EFILE)

will return the value:

	test_directory


### DLURLSCHEME ( datalink )

The DLURLSCHEME function returns the scheme from a DATALINK value.
The value will always be in lower case. The argument must be a value
with data type DATALINK.

The result of the function is text. If the argument is null, the result is
the null value. If the DATALINK value only includes the comment the result
returned is a zero length string.

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://pgbadger.darold.net/images/logo.png','URL','a comment')

then the following function operating on that value:

	DLURLSCHEME(EFILE)

will return the value:

	http

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('/var/log/postgresql/postgresql-11.log','FILE','PostgreSQL log file')
or
	DLVALUE('/var/log/postgresql/postgresql-11.log',NULL,'PostgreSQL log file')

the return value is:

	file

### DLURLSERVER ( datalink )

The DLURLSERVER function returns the file server from a DATALINK value when
the uri scheme is http. The value returned is always in lower case.

The argument must be an expression that results in a value with data type
DATALINK.

The result of the function is text. If the argument is null, the result is
the null value.  If the DATALINK value only includes the comment the result
returned is a zero length string.

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://pgbadger.darold.net/index.html','URL','a comment')

then the following function operating on that value:

	DLURLSERVER(EFILE)

will return the value:

	pgbadger.darold.net


### DLURLCOMPLETE ( datalink )

The DLURLCOMPLETE function returns the data location attribute from a
DATALINK value in a form of an URL. When _datalink_ is a
DATALINK column defined with the attribute READ PERMISSION DB, the
value includes a file access token.

The argument must be a value with data type DATALINK.

The result of the function of type text. If the argument is null, the result
is the null value. If the DATALINK value only includes the comment the result
returned is a zero length string.

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://www.darold.net/logo.png','URL','a comment')

the following function operating on that value:

	DLURLCOMPLETE(EFILE)

returns:

	http://www.darold.net/00f59e3-60a5-4bfa-a45b-214ccb08e425;logo.png

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the access token.


### DLURLCOMPLETEONLY ( datalink )

The DLURLCOMPLETEONLY function returns the data location attribute
from a DATALINK value in form of an URL. The value returned never
includes a file access token.

The argument must be a DATALINK data type value.

The result of the function is text. If the argument is null, the result is
the null value.

If the DATALINK value only includes a comment, the result is a zero length
string.

**Examples**

Given a DATALINK value that was inserted into a DATALINK column EFILE
(defined with READ PERMISSION DB) using function:

	DLVALUE('http://pgbadger.darold.net/logo.png','URL','a comment')

the following function operating on that value:

	DLURLCOMPLETEONLY(EFILE)

returns:

	http://pgbadger.darold.net/logo.png


### DLURLPATH ( datalink )

The DLURLPATH function returns the full path to the external file linked
from a DATALINK value. When _datalink_ is a DATALINK column defined with
the attribute READ PERMISSION DB, the value includes a file access token.

The argument must be an expression that results in a value with data type
DATALINK.

The result of the function is text. If the argument is null, the result is
the null value. If the DATALINK value only includes the comment the result
returned is a zero length string.

**Examples**

Given a DATALINK value that was inserted into column EFILE using the function:

	DLVALUE('http://pgbadgr.darold.net/images/logo.png','URL','a comment')

then the following function operating on that value:

	DLURLPATH(EFILE)

returns the value:

	/images/00f59e3-60a5-4bfa-a45b-214ccb08e425;logo.png

(where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the access token)


### DLURLPATHONLY ( datalink )

The DLURLPATHONLY function returns the full path to an external file linked
from a DATALINK value. The value returned never includes a file access token.

The argument must be an expression that results in a value with data type
DATALINK. The result of the function is text. If the argument is null, the
result is the null value. If the DATALINK value only includes the comment the
result returned is a zero length string.

**Examples**

Given a DATALINK value that was inserted into column EFILE using function:

	DLVALUE('http://pgbadger.darold.net/images/logo.png','URL','a comment')

then the following function operating on that value:

	DLURLPATHONLY(EFILE)

returns the value:

	/images/logo.png


### DLURLCOMPLETEWRITE ( datalink )

The DLURLCOMPLETEWRITE function returns the complete URL value from a DATALINK
value in the form of an URL. If the DATALINK value comes from a DATALINK
column defined with WRITE PERMISSION ADMIN, a write token is included in the
return value.

The returned value can be used to locate and update the linked file. If the
DATALINK column is defined with another WRITE PERMISSION option (not ADMIN)
or NO LINK CONTROL, DLURLCOMPLETEWRITE returns just the URL value without a
write token. If the file reference is derived from a DATALINK column defined
with WRITE PERMISSION FS, a token is not required to write to the file, because
write permission is controlled by the file system.

The argument must be a value with data type DATALINK.

The result of the function is text. If the argument is null, the result is
the null value. If the DATALINK value only includes a comment, the result is
a zero length string.

**Examples**

Given a DATALINK value that was inserted into a DATALINK column EFILE (defined
with WRITE PERMISSION ADMIN) using function:

	DLVALUE('http://pgbadger.darold.net/logo.png','URL','a comment')

the following function operating on that value:

	DLURLCOMPLETEWRITE(EFILE)

returns:

	http://pgbadger.darold.net/00f59e3-60a5-4bfa-a45b-214ccb08e425;logo.png

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the write token. If EFILE
is not defined with WRITE PERMISSION ADMIN, the write token will not be present.


### DLURLPATHWRITE ( datalink )

The DLURLPATHWRITE function returns the full path necessary to access an
external file given from a DATALINK value in a form of an absolute file path.
The value returned includes a write token if the DATALINK value specified as
parameter comes from a DATALINK column defined with WRITE PERMISSION ADMIN.

If the DATALINK column is defined with other WRITE PERMISSION options (not
ADMIN) or NO LINK CONTROL, DLURLPATHWRITE returns the full path to the external
file without a write token. If the file reference is derived from a DATALINK
column defined with WRITE PERMISSION FS, a token is not required to write to
the file, because write permission is controlled by the file system.

The argument must be an expression that results in a value with data type
DATALINK.

The result of the function is text. If the argument is null, the result is the
null value. If the DATALINK value only includes a comment, the result is a zero
length string.

**Examples**

Given a DATALINK value that was inserted into a DATALINK column EFILE (defined
with WRITE PERMISSION ADMIN) using function:

	DLVALUE('http://pgbadger.darold.net/images/logo.png','URL','a comment')

the following function operating on that value:

	DLURLPATHWRITE(EFILE)

returns:

	/images/00f59e3-60a5-4bfa-a45b-214ccb08e425;logo.png

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the write token. If EFILE
is not defined with WRITE PERMISSION ADMIN, the write token will not be present.


### DLNEWCOPY ( datalink, data-location, has-token )

The DLNEWCOPY function returns a DATALINK value indicating that the referenced
file has changed with the new URI in the DATALINK value.

The value is assigned to a DATALINK column as a result of an UPDATE statement.
If the DATALINK column/directory is defined with option RECOVERY YES, the new
version of the linked file is archived asynchronously.

If DLNEWCOPY is not called in  an UPDATE statement an error is returned.

**datalink**

The DATALINK to be modified. In future implementation this parameter will
be removed in respect to the standard SQL as the value must be taken from
the left operand of the UPDATE statement.

**data-location**

A text expression that specifies a complete URL value. The value may have been
obtained earlier by a SELECT statement through the DLURLCOMPLETEWRITE function.

**has-token**

A boolean value that indicates whether the URL contains a write token.  An error
occurs if the token embedded in the data location is not valid.

The result of the function is a DATALINK value.

Parameters data-location and has-token can not be null.

For a DATALINK column defined with WRITE PERMISSION ADMIN REQUIRING TOKEN FOR
UPDATE, the write token must be in the data location to complete the SQL UPDATE
statement.

On the other hand, for WRITE PERMISSION ADMIN NOT REQUIRING TOKEN FOR UPDATE,
the write token is not required, but is allowed in the data location.

For a DATALINK column defined with WRITE PERMISSION ADMIN and REQUIRING TOKEN
FOR UPDATE, the write token must be the same as the one used to open the
specified file, if it was opened.

For any WRITE PERMISSION ADMIN column, even if the write token has expired,
the token is still considered valid as long as the transaction is still open.

In a case where no file update has taken place, or the DATALINK file is
linked with other options, such as WRITE PERMISSION BLOCKED/FS or NO
LINK CONTROL, this function will behave like DLVALUE.

**Examples**

Given a DATALINK value that was inserted into column EFILE (defined with
WRITE PERMISSION ADMIN REQUIRING TOKEN FOR UPDATE) using function:

	DLVALUE('file:///home/postgres/datafiles/file1.txt','FILE','A local file')

Use the scalar function DLURLCOMPLETEWRITE to fetch the value:

	SELECT DLURLCOMPLETEWRITE(EFILE) FROM DL_EXAMPLE WHERE ...

It returns:

	/home/postgres/datafiles/00f59e3-60a5-4bfa-a45b-214ccb08e425;file1.txt

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the write token.

Use the above value to locate and update the content of the file. Issue the
following SQL UPDATE statement to indicate that the file has been successfully
changed:

	UPDATE t1 SET EFILE = DLNEWCOPY(EFILE, 'file:///home/postgres/datafiles/00f59e3-60a5-4bfa-a45b-214ccb08e425;file1.txt', 1)
	WHERE ...

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the same write token used
to modify the file referenced by the URL value. Note that if EFILE is defined
with WRITE PERMISSION ADMIN NOT REQUIRING TOKEN FOR UPDATE, the write token is
not required in the above example.

### DLPREVIOUSCOPY ( datalink, data-location , has-token )

The DLPREVIOUSCOPY function returns a DATALINK value indicating that the
previous version of the file should be restored.

The value is assigned to a DATALINK column as a result of an UPDATE statement.
This function restore the linked file from the previously committed version.

If DLPREVIOUSCOPY is not called in a result of an UPDATE statement an error is
returned.

**datalink**

The DATALINK to be modified. In future implementation this parameter will
be removed in respect to the standard SQL as the value must be taken from
the left operand of the UPDATE statement.

**data-location**

A text expression that specifies the complete URL value. The value may have
been obtained earlier by a SELECT statement through the DLURLCOMPLETEWRITE
function.

**has-token**

An boolean value that indicates whether the URL contains a write token.
An error occurs if the token embedded in the data location is not valid.

The result of the function is a DATALINK value.

Parameters data-location and has-token can not be null.

For a DATALINK column defined with WRITE PERMISSION ADMIN REQUIRING TOKEN
FOR UPDATE, the write token must be in the data location to complete the
SQL UPDATE statement. On the other hand, for WRITE PERMISSION ADMIN NOT
REQUIRING TOKEN FOR UPDATE, the write token is not required, but is allowed
in the data location.

For a DATALINK column defined with WRITE PERMISSION ADMIN REQUIRING TOKEN
FOR UPDATE, the write token must be the same as the one used to open the
specified file, if it was opened.

For any WRITE PERMISSION ADMIN column, even if the write token has expired,
the token is still considered valid as long as the transaction is open.

**Examples**

Given a DATALINK value that was inserted into column EFILE (defined with
WRITE PERMISSION ADMIN REQUIRING TOKEN FOR UPDATE and RECOVERY YES) using
function:

	DLVALUE('http://pgcluu.darold.net/index.html','URL','Main page of pgCluu site')

Use the scalar function DLURLCOMPLETEWRITE to fetch the value:

	SELECT DLURLCOMPLETEWRITE(EFILE) FROM DL_EXAMPLE WHERE ...

It returns:

	http://pgcluu.darold.net/00f59e3-60a5-4bfa-a45b-214ccb08e425;index.html

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the write token.

Use the above value to locate and update the content of the file. Issue the
following SQL UPDATE statement to back out the file changes and restore
to the previous committed version:

	UPDATE DL_EXAMPLE SET EFILE = DLPREVIOUSCOPY('http://pgcluu.darold.net/00f59e3-60a5-4bfa-a45b-214ccb08e425;index.html', 1) WHERE ...

where 00f59e3-60a5-4bfa-a45b-214ccb08e425 represents the same write token used
to modify the file referenced by the URL value. Note that if EFILE is defined
with WRITE PERMISSION ADMIN NOT REQUIRING TOKEN FOR UPDATE, the write token is
not required in the above example.

### DLREPLACECONTENT ( datalink, data-location-target , data-location-source , comment )

The DLREPLACECONTENT function returns a DATALINK value. When the
function is on the right hand side of a SET clause in an UPDATE statement, or
is in a VALUES clause in an INSERT statement, the assignment of the
returned value results in replacing the content of a file by another file and
then creating a link to it.

The actual file replacement process is done during commit processing of the
current transaction.

**datalink-expression**

The DATALINK to be modified. In future implementation this parameter will
be removed in respect to the standard SQL as the value must be taken from
the left operand of the UPDATE statement.

**data-location-target**

A text expression that specifies a complete URL value.

As long as a DATALINK parameter is specified it must be the same URI than
in the DATALINK.

**data-location-source**

A text expression that specifies the data location of a file in URL format.
As a result of an assignment in an UPDATE or an INSERT statement, this file
is renamed to the name of the file that is pointed to by data-location-target;
the ownership and permission attributes of the target file are retained.

There is a restriction that data-location-source can only be one of the
following:

  - A zero-length value
  - A NULL value
  - The value of data-location-target plus a suffix string. The suffix
    string can be up to 20 characters in length. The characters of the
    suffix string must belong to the URL character set. Moreover, the
    string cannot contain a “\” character under the UNC scheme, or the
    “/” character under other valid schemes.

**comment-string**

An optional text value that contains a comment or additional location
information.

The result of the function is a DATALINK value. If data-location-target is
null, the result is the null value. If data-location-source is null, a
zero-length string, or exactly the same as data-location-target, the effect
of DLREPLACECONTENT is the same as DLVALUE.

**Examples**

Replace the content of a linked file by another file. Given a DATALINK value
that was inserted into column EFILE using the following INSERT statement:

	INSERT INTO DL_EXAMPLE (ID, EFILE) VALUES (1, DLVALUE('http://www.darold.net/logo.png'));

Replace the content of this file with another file by issuing the following
SQL UPDATE statement:

	UPDATE DL_EXAMPLE SET EFILE = DLREPLACECONTENT('http://www.darold.net/logo.png', 'http://www.darold.net/logo.png.new') WHERE ID = 1;

## Authors

Gilles Darold < gilles@darold.net >

## License

This extension is free software distributed under the PostgreSQL Licence.

        Copyright (c) 2015-2018, Gilles Darold

