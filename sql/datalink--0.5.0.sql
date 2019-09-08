-- Datalink extension for PostgreSQL
-- Author Gilles Darold (gilles@darold.net)
-- Copyright (c) 2015-2019 Gilles Darold - All rights reserved.

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION datalink" to load this file. \quit

-- Table used to store per datalink options normally set as attributes to
-- columns definition but there is no hook to the parser so no chance to
-- extend the syntax. The dirname attribute might stores the nspname.relname.attname
-- as a single string. We use it to extend the feature by adding a base uri
-- that can be used to limit the length of the URI by removing the base part.
-- Directory options are not limited to a column but each datalink embedded
-- the directory options that must appply to it. This is also an extension
-- to the standard but it is possible to use one directory per column.
CREATE TABLE pg_datalink_bases
(
        dirid serial ,
        dirname text PRIMARY KEY , -- Should be splitted into nspname/relname/attname
        base uri NOT NULL,
        -- SQL/MED WD 2003
        --
        -- NO LINK CONTROL: Although every file path must conform to the syntax for such
        -- identifiers as specified by the external file server, it is permitted for there
        -- to be no external object referenced by that file path. Value: false.
        -- FILE LINK CONTROL: Every file path must reference an existing external object.
        -- Further file control depends on the link control options. Value: true.
        -- Default is false, NO LINK CONTROL, in this case all others options do not apply.
        linkcontrol boolean DEFAULT false,
        -- INTEGRITY ALL: External objects referenced by file paths cannot be deleted or
        -- renamed, except possibly through the use of SQL operators. Value: true.
        -- INTEGRITY SELECTIVE: External objects referenced by file paths can be deleted
        -- or renamed using operators provided by the file server. Value: false.
        -- With this extention there is no guaranty that a file has not been changed
        -- at filesystem level then force the default to false (SELECTIVE).
        integrity boolean DEFAULT false,
        -- READ PERMISSION FS: Permission to read external objects referenced by datalinks
        -- is determined by the file server. Value: false.
        -- READ PERMISSION DB: Permission to read external objects referenced by datalinks
        -- is determined by the SQL-implementation. Value: true.
        -- By default read permission is at FS side.
        readperm boolean DEFAULT false,
        -- WRITE PERMISSION FS: Permission to write external objects referenced by datalinks
        -- is determined by the file server. Value: False.
        -- WRITE PERMISSION ADMIN: Permission to write external objects referenced by datalinks
        -- is determined by the SQL-implementation. Value: True.
        -- By default write permission is at FS side.
        writeperm boolean DEFAULT false,
        -- WRITE PERMISSION BLOCKED: Write access to external objects referenced by datalinks
        -- is not available. In order to update a file, it should be copied, the copy should
        -- then be updated, and finally the DATALINK value should be updated to point to the
        -- the new copy of the file. This is the default and only supported mechanism of the
        -- extension when file link control is enabled. Value: False.
        writeblocked boolean DEFAULT false,
        -- Write access has two additional authorization.
        -- ADMIN REQUIRING TOKEN FOR UPDATE: Write access is governed by the SQL server
        -- and involves write access token for modifying file content.
        -- ADMIN NOT REQUIRING TOKEN FOR UPDATE: write access governed by SQL server without
        -- involving write access token for modifying file content. We always use token by default.
        -- Applied only if INTEGRITY ALL and RECOVERY YES, no utility otherwise.
        writetoken boolean DEFAULT true,
        -- RECOVERY YES: Enables point in time recovery of external objects referenced by datalinks. Value: true.
        -- RECOVERY NO: PITR of external objects referenced by datalinks is disabled. Value: false.
        recovery boolean DEFAULT false,
        -- ON UNLINK RESTORE: When an external object referenced by a datalink is unlinked,
        -- the external file server attempts to reinstate the ownership and permissions that
        -- existed when that object was linked.
        -- ON UNLINK DELETE: An external object referenced by a datalink is deleted when it
        -- is unlinked.
        -- Default to NONE, NO LINK CONTROL is the default.
        onunlink text DEFAULT 'NONE' CHECK (onunlink IN ('NONE', 'RESTORE', 'DELETE'))
);
REVOKE ALL ON pg_datalink_bases FROM PUBLIC;
GRANT SELECT ON pg_datalink_bases TO PUBLIC;

-- Table used to store path to external files that must be archived
-- after call to DLVALUE() and DLNEWCOPY() when RECOVERY YES is set.
CREATE TABLE pg_datalink_archives
(
	base integer, -- Id of the base directory
	url uri, -- URI of the file to archive
	PRIMARY KEY (base, url)
);
REVOKE ALL ON pg_datalink_archives FROM PUBLIC;
GRANT SELECT ON pg_datalink_archives TO PUBLIC;

-- When a base directory is inserted or updated verify that
-- all options are compatible as per SQL/MED ISO definition
CREATE OR REPLACE FUNCTION verify_datalink_options() RETURNS trigger AS $$
DECLARE
    v_directory record;
    v_path text;
    v_dstpath text;
    v_ret boolean;
BEGIN
    -- With NO LINK CONTROL other options do not apply
    -- so no further check and force default values
    IF NOT NEW.linkcontrol THEN
        NEW.integrity := false;
        NEW.readperm := false;
        NEW.writeperm := false;
        NEW.writeblocked := false;
        NEW.recovery := false;
        NEW.onunlink := 'NONE';
        RETURN NEW;
    ELSE
        IF NEW.onunlink = 'NONE' THEN
            RAISE EXCEPTION 'With FILE LINK CONTROL either ON UNLINK RESTORE or ON UNLINK DELETE shall be specified.';
        END IF;
        -- Forced when FILE LINK CONTROL is specified
        NEW.writeblocked := true;
    END IF;
    -- If INTEGRITY SELECTIVE is specified, then READ PERMISSION FS,
    -- WRITE PERMISSION FS and RECOVERY NO shall be specified.
    IF NOT NEW.integrity THEN
        IF NEW.readperm OR NEW.writeperm OR NEW.recovery THEN
            RAISE EXCEPTION 'If INTEGRITY SELECTIVE is specified, then READ PERMISSION FS, WRITE PERMISSION FS and RECOVERY NO shall be specified.';
        END IF;
    END IF;
    -- If READ PERMISSION DB is specified, then either WRITE PERMISSION BLOCKED
    -- or WRITE PERMISSION ADMIN shall be specified.
    IF NEW.readperm THEN
        IF NOT NEW.writeperm AND NOT NEW.writeblocked THEN
            RAISE EXCEPTION 'If READ PERMISSION DB is specified, then either WRITE PERMISSION BLOCKED or WRITE PERMISSION ADMIN shall be specified.';
        END IF;
    END IF;
    -- If WRITE PERMISSION ADMIN is specified, then READ PERMISSION DB shall be specified
    IF NEW.writeperm AND NOT NEW.readperm THEN
        RAISE EXCEPTION 'If WRITE PERMISSION ADMIN is specified, then READ PERMISSION DB shall be specified.';
    END IF;
    -- If either WRITE PERMISSION BLOCKED or WRITE PERMISSION ADMIN is specified,
    -- then INTEGRITY ALL and <unlink option> shall be specified. In our case
    -- unlink option is always set.
    IF NEW.writeblocked OR NEW.writeperm THEN
        IF NOT NEW.integrity OR NEW.onunlink = 'NONE' THEN
            RAISE EXCEPTION 'If either WRITE PERMISSION BLOCKED or WRITE PERMISSION ADMIN is specified, then INTEGRITY ALL shall be specified and <unlink option> shall be specified.';
        END IF;
    END IF;
    -- If WRITE PERMISSION FS is specified, then READ PERMISSION FS and RECOVERY NO
    -- shall be specified and <unlink option> shall not be specified.
    IF NOT NEW.writeperm THEN
        IF NEW.readperm OR NEW.recovery OR NEW.onunlink != 'NONE' THEN
            RAISE EXCEPTION 'If WRITE PERMISSION FS is specified, then READ PERMISSION FS and RECOVERY NO shall be specified and <unlink option> shall not be specified.';
        END IF;
    END IF;
    -- If RECOVERY YES is specified, then either WRITE PERMISSION BLOCKED or
    -- WRITE PERMISSION ADMIN shall be specified.
    IF NEW.recovery THEN
        IF NOT NEW.writeblocked OR NOT NEW.writeperm THEN
            RAISE EXCEPTION 'If RECOVERY YES is specified, then either WRITE PERMISSION BLOCKED or WRITE PERMISSION ADMIN shall be specified.';
        END IF;
    END IF;
    -- If UNLINK DELETE is specified, then READ PERMISSION DB and WRITE PERMISSION BLOCKED shall be specified.
    IF NEW.onunlink = 'DELETE' THEN
        IF NOT NEW.readperm OR NOT NEW.writeblocked THEN
            RAISE EXCEPTION 'If UNLINK DELETE is specified, then READ PERMISSION DB and WRITE PERMISSION BLOCKED shall be specified.';
        END IF;
    END IF;
    -- If UNLINK RESTORE is specified, then INTEGRITY ALL and WRITE PERMISSION BLOCKED shall be specified.
    IF NEW.onunlink = 'RESTORE' THEN
        IF NOT NEW.integrity OR NOT NEW.writeblocked THEN
            RAISE EXCEPTION 'If UNLINK RESTORE is specified, then READ PERMISSION DB and WRITE PERMISSION BLOCKED shall be specified.';
        END IF;
    END IF;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- To be able to unlink a datalink, add a trigger
CREATE TRIGGER trg_pg_datalink_bases
    BEFORE INSERT OR UPDATE ON pg_datalink_bases
    FOR EACH ROW
    EXECUTE FUNCTION verify_datalink_options();

-- Enter default directories FILE and URL with there respective default options
-- By default we considere that Datalink files must be stored under directory
-- ${PGDATA}/pg_datalink/ if the base specified as parameter is NULL or
-- set to 'FILE'. This default path can be changed by a GUC datalink.pg_external_files.
-- Default for both entry is NO LINK CONTROL

INSERT INTO pg_datalink_bases (dirid, dirname, base, linkcontrol) VALUES (-1, 'FILE', 'file:///var/lib/pg_datalink/', false);
-- Same for the defaut base for remote URL, default path should be changed by a GUC
INSERT INTO pg_datalink_bases (dirid, dirname, base, linkcontrol) VALUES ( 0, 'URL', 'http://', false );

-- Include table pg_datalink_bases into pg_dump without default values
-- they are always inserted at extension creation time.
SELECT pg_catalog.pg_extension_config_dump('pg_datalink_bases', 'WHERE dirname NOT IN (''FILE'', ''URL'')');


-- The DATALINK data type
CREATE TYPE datalink AS
(
        dl_base integer, -- Id of the base directory
        dl_path uri, -- Url of the external file
        dl_comment text, -- A comment
        dl_token uuid, -- Current active token
        dl_prev_token uuid -- Previous active token
	-- dl_unlink_privileges -- Privileges to be restored on unlink NOT USE NOW
);

REVOKE ALL ON TYPE datalink FROM PUBLIC;
GRANT USAGE ON TYPE datalink TO PUBLIC;

----------------------------------------------------------------------------
-- Add event trigger on CREATE TABLE to create index and triggers on table
-- with datalink.
----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION add_datalink_trigger()
  RETURNS event_trigger
 LANGUAGE plpgsql
  AS $$
DECLARE
  objtbl record;
  obj record;
BEGIN
    FOR objtbl IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        FOR obj IN SELECT a.atttypid,a.attname,t.typname FROM pg_attribute a JOIN pg_type t ON (a.atttypid = t.oid) WHERE a.attrelid=objtbl.objid
        LOOP
            IF obj.typname = 'datalink' THEN
                -- A datalink is unique by the indexed three columns
                EXECUTE format('CREATE UNIQUE INDEX ON %s (((%s).dl_base), ((%s).dl_path), ((%s).dl_comment));', objtbl.object_identity, quote_ident(obj.attname), quote_ident(obj.attname), quote_ident(obj.attname));
                -- To be able to unlink a datalink, add a trigger
                EXECUTE format('CREATE TRIGGER "dltrg_%s_upd" BEFORE UPDATE ON %s FOR EACH ROW WHEN (NEW.%s IS NULL OR (NEW.%s).dl_path = '''') EXECUTE FUNCTION dlunlink();', obj.attname, objtbl.object_identity, quote_ident(obj.attname), quote_ident(obj.attname));
                EXECUTE format('CREATE TRIGGER "dltrg_%s_del" BEFORE DELETE ON %s FOR EACH ROW EXECUTE FUNCTION dlunlink();', obj.attname, objtbl.object_identity);
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER datalink_event_trigger_ddl ON ddl_command_end
   WHEN TAG IN ('CREATE TABLE')
   EXECUTE FUNCTION add_datalink_trigger();
--------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------

-- I/O Funtions
CREATE FUNCTION datalink_copy_localfile(text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_unlink_localfile(uri) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_read_localfile(text, bigint, bigint) RETURNS bytea AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE;
CREATE FUNCTION datalink_write_localfile(text, bytea) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_rename_localfile(text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_createlink_localfile(text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_relink_localfile(text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_register_token(text, text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_verify_token(text, boolean, text) RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_is_symlink(text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION datalink_symlink_target(text) RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;

-- Create SQL function used to create a token for reading
CREATE FUNCTION datalink_register_accesstoken(uri, text) RETURNS boolean AS $$
DECLARE
    v_token uuid;
    v_path text;
    v_ret boolean;
BEGIN
    SELECT (regexp_match($1::text, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
    IF v_token IS NULL THEN
        SELECT (regexp_match($1::text, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
        IF v_token IS NULL THEN
            RAISE EXCEPTION 'can not found a token in url "%"', $1;
        END IF;
    END IF;
    -- Get the path without token to register with the token and access mode
    SELECT uri_get_path($1) INTO v_path;
    SELECT datalink_register_token(v_token::text, $2, v_path) INTO v_ret;
    IF NOT v_ret THEN
        RAISE EXCEPTION 'can not register token!';
    END IF;

    RETURN v_ret;
END
$$ LANGUAGE plpgsql STRICT;

-- Create SQL function used to create a token for reading
CREATE FUNCTION datalink_register_readtoken(text) RETURNS boolean AS $$
    SELECT datalink_register_accesstoken($1::uri, 'R'::text);
$$ LANGUAGE SQL STRICT;

-- Create SQL function used to create a token for writing
CREATE FUNCTION datalink_register_writetoken(text) RETURNS boolean AS $$
    SELECT datalink_register_accesstoken($1::uri, 'W'::text);
$$ LANGUAGE SQL STRICT;

-- Function to insert a Datalink token into an URL
CREATE OR REPLACE FUNCTION add_token_to_url(vpath text, vtoken text) RETURNS text AS $$
    SELECT CASE WHEN vpath ~ '\/' THEN
        -- If there is a / replace last one with '/token;'
        regexp_replace(vpath, '^(.*)\/([^\/]+)$', '\1/'||vtoken||';\2')
    ELSE
        -- otherwise just prefix the name with 'token;' 
        regexp_replace(vpath, '^(.*)$', vtoken||';\1')
    END;
$$ LANGUAGE SQL STRICT;

-- Function to remove the token part from the uri
CREATE OR REPLACE FUNCTION remove_token_from_url(uri) RETURNS uri AS $$
DECLARE
    v_url uri;
BEGIN
    SELECT regexp_replace($1::text, '^(.*\/)[0-9a-f\-]+;([^\/;]+)$', '\1\2') INTO v_url;
    IF v_url IS NULL THEN
        SELECT regexp_replace($1::text, '^[0-9a-f\-]+;([^\/;]+)$', '\1') INTO v_url;
        IF v_url IS NULL THEN
            RETURN $1;
        END IF;
    END IF;

    RETURN v_url;
END
$$ LANGUAGE plpgsql STRICT;

-- Function use to return the token from an url and validate it
-- verify_token_from_uri(Uri-with-token, write-access)
CREATE OR REPLACE FUNCTION verify_token_from_uri(uri, boolean) RETURNS uuid AS $$
DECLARE
    v_token text;
    v_path text;
    v_ret boolean;
BEGIN
    SELECT (regexp_match($1::text, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
    IF v_token IS NULL THEN
        SELECT (regexp_match($1::text, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
        IF v_token IS NULL THEN
            RAISE EXCEPTION 'can not found a token in url "%"', $1;
        END IF;
    END IF;

    -- Verify that the token length is a uuid v4
    IF length(v_token) != 36 THEN
        RAISE EXCEPTION 'invalid token length in url "%"', $1;
    END IF;

    -- Remove token from the uri and get the path
    SELECT uri_get_path(remove_token_from_url($1)) INTO v_path;
    -- Verify that we have a valid token to access to the file
    SELECT is_valid_token(v_token::uuid, $2, v_path) INTO v_ret;
    IF NOT v_ret THEN
        RAISE EXCEPTION 'Invalid write token "%s" to access "%".', v_token, $1;
    END IF;

    RETURN v_token::uuid;
END
$$ LANGUAGE plpgsql VOLATILE STRICT;

-- Verify that this is a valid token and that it has not expired
-- Function is_valid_token(Token, For-writing, pathonly-without-token)
CREATE OR REPLACE FUNCTION is_valid_token(uuid, boolean, text) RETURNS boolean AS $$
DECLARE
    v_path text;
    v_path_wt text;
BEGIN
    -- When the token is valid and for the right access mode
    -- the file path authorized with this token is returned
    SELECT datalink_verify_token($1::text, $2, $3) INTO v_path;
    IF v_path IS NULL THEN
        RAISE EXCEPTION 'invalid token "%" to access file "%"', $1, $3;
    ELSE
        -- Verify that the file path requested for access
        -- is the same as the one stored with the token
        SELECT add_token_to_url($3, $1::text) INTO v_path_wt;
        IF v_path_wt != v_path THEN
            RAISE EXCEPTION 'Invalid path "%" for token "%", "%" <> "%"', $3, $1, v_path_wt, v_path;
        END IF;
    END IF;

    RETURN true;
END
$$ LANGUAGE plpgsql VOLATILE STRICT;

-- Function to read a local file and return its content as a bytea
-- All file content will be stored in memory.
CREATE OR REPLACE FUNCTION datalink_read_localfile(text) RETURNS bytea AS $$
    SELECT datalink_read_localfile($1, 0, -1);
$$ LANGUAGE SQL STRICT;

-- Function to rebase an URL through the directory base
CREATE FUNCTION dl_url_rebase(uri, integer) RETURNS uri AS $$
    SELECT uri_rebase_url($1, base) FROM pg_datalink_bases WHERE dirid = $2;
$$ LANGUAGE SQL STRICT;

-- Function used to retrieve all base directory information for a datalink
-- following its directory id or name
-- dl_directory_base(directory-id, directory-name)
CREATE OR REPLACE FUNCTION dl_directory_base(integer, text) RETURNS pg_datalink_bases AS $$
DECLARE
    v_directory pg_datalink_bases%rowtype;
BEGIN
    -- Both NULL parameters is not possible
    IF $1 IS NULL AND $2 IS NULL THEN
        RAISE EXCEPTION 'Datalink base directory NULL can not be found.';
    END IF;

    -- Extract directory information
    IF $1 IS NOT NULL THEN
        SELECT * INTO v_directory FROM pg_datalink_bases WHERE dirid = $1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Datalink base directory with id "%" is not found.', $1;
        END IF;
    ELSE
        SELECT * INTO v_directory FROM pg_datalink_bases WHERE dirname=$2;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Datalink base directory with name "%" is not found.', $2;
        END IF;
    END IF;
    RETURN v_directory;
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION dl_directory_base(integer) RETURNS pg_datalink_bases AS $$
    SELECT dl_directory_base($1, NULL);
$$ LANGUAGE SQL STRICT;

CREATE FUNCTION dl_directory_base(text) RETURNS pg_datalink_bases AS $$
    SELECT dl_directory_base(NULL, $1);
$$ LANGUAGE SQL STRICT;

-- Function used to return a relative path from a base
CREATE FUNCTION dl_relative_path(uri, uri) RETURNS text AS $$
DECLARE
    v_uri uri;
    v_path text;
    v_ret boolean;
BEGIN
    -- Start to rebase the uri
    SELECT uri_rebase_url($1, $2) INTO v_uri;
    -- Then get relative path
    IF uri_get_scheme(v_uri) = 'file' THEN
        SELECT uri_get_relative_path(v_uri, $2) INTO v_path;
    ELSE
        IF uri_get_host($2) != '' THEN
            SELECT uri_get_relative_path(v_uri, $2) INTO v_path;
        ELSE
            RETURN $1;
        END IF;
    END IF;
    -- In case we just have the base return the uri
    IF v_path = '' OR v_path IS NULL THEN
        RETURN v_uri;
    END IF;

    RETURN v_path;
END
$$ LANGUAGE plpgsql STRICT;


---------------------------------------------------------------
-- Datalink Standard ISO functions
---------------------------------------------------------------

-- The DLCOMMENT function returns the comment value from a DataLink value.
-- DLCOMMENT(DataLink)
CREATE FUNCTION dlcomment(datalink) RETURNS text AS $$
    SELECT ($1).dl_comment;
$$ LANGUAGE SQL STRICT;

-- The DLURLCOMPLETEONLY function returns the complete URL
-- value from a DataLink value.
-- DLURLCOMPLETEONLY(DataLink)
CREATE FUNCTION dlurlcompleteonly(datalink) RETURNS text AS $$
    SELECT CASE WHEN ($1).dl_path = '' THEN '' ELSE dl_url_rebase(($1).dl_path, ($1).dl_base)::text END;
$$ LANGUAGE SQL STRICT;

-- The DLURLPATHONLY function returns the path and file name from a DataLink value
-- DLURLPATHONLY(Datalink)
CREATE FUNCTION dlurlpathonly(datalink) RETURNS text AS $$
    SELECT CASE WHEN ($1).dl_path = '' THEN '' ELSE uri_get_path(dl_url_rebase(($1).dl_path, ($1).dl_base)) END;
$$ LANGUAGE SQL STRICT;

-- The DLURLSCHEME function returns the scheme from a Datalink value
-- DLURLSCHEME(Datalink)
CREATE OR REPLACE FUNCTION dlurlscheme(datalink) RETURNS text AS $$
    SELECT CASE WHEN ($1).dl_path = '' THEN '' ELSE lower(uri_get_scheme(dl_url_rebase(($1).dl_path, ($1).dl_base))) END;
$$ LANGUAGE SQL STRICT;

-- The DLURLSERVER function returns the file server from a Datalink value
-- DLURLSERVER(Datalink)
CREATE FUNCTION dlurlserver(datalink) RETURNS text AS $$
DECLARE
    v_server  text;
BEGIN
    -- Return an error id the URI is not an URL
    IF uri_get_scheme(($1).dl_path) = 'file' THEN
        RAISE WARNING 'Function dlurlserver() can only be used with link type URL.';
        RETURN NULL;
    END IF;
    -- Return a zero length string if the URI is empty
    IF ($1).dl_path = '' THEN
        RETURN '';
    END IF;
    -- Only URL can have server
    IF uri_get_scheme(($1).dl_path) = '' OR uri_get_scheme(($1).dl_path) = 'file' THEN
        RETURN NULL;
    END IF;
    SELECT lower(uri_get_host(dl_url_rebase(($1).dl_path, ($1).dl_base))) INTO v_server;
    RETURN v_server;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLLINKTYPE function returns the linktype value from a DATALINK value (FILE or URL)
-- DLLINKTYPE(Datalink)
CREATE OR REPLACE FUNCTION dllinktype(datalink) RETURNS text AS $$
    SELECT dirname FROM pg_datalink_bases WHERE dirid = ($1).dl_base;
$$ LANGUAGE SQL STRICT;

-- Function to get defaut directory to use following the URI
CREATE OR REPLACE FUNCTION dl_default_linktype(uri) RETURNS text AS $$
SELECT CASE WHEN uri_get_scheme($1) = '' OR uri_get_scheme($1) = 'file' THEN 'FILE' ELSE 'URL' END;
$$ LANGUAGE SQL STRICT;

-- The DLFILESIZE function returns the size of the file represented by a DataLink value.
-- DLFILESIZE(DataLink)
CREATE FUNCTION dlfilesize(datalink) RETURNS bigint AS $$
DECLARE
    v_uri uri;
    v_size bigint;
    v_scheme text;
BEGIN
    SELECT dl_url_rebase(($1).dl_path, ($1).dl_base) INTO v_uri;
    SELECT uri_get_scheme(v_uri) INTO v_scheme;
    IF v_scheme = '' OR v_scheme = 'file' THEN
        SELECT uri_localpath_size(v_uri) INTO v_size;
    ELSE
        SELECT uri_remotepath_size(v_uri) INTO v_size;
    END IF;

    RETURN v_size;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLFILESIZEEXACT function returns the size of the file represented by a DataLink value.
-- DLFILESIZEEXACT(DataLink) 
CREATE FUNCTION dlfilesizeexact(datalink) RETURNS bigint AS $$
    SELECT dlfilesize($1);
$$ LANGUAGE SQL STRICT;

-- SQL/MED functions
-- The DLVALUE function returns a DataLink value for UPDATE statement.
-- As we can not obtain obtain the datalink impacted by the update in
-- plpgsql this function received the mofified datalink at first argument.
-- DLVALUE(datalink, data-location, directory-name, comment)
CREATE FUNCTION dlvalue(datalink, uri, text, text) RETURNS datalink AS $$
DECLARE
    v_directory record;
    v_base uri;
    v_uri uri;
    v_ret boolean;
    v_comment text := $4;
    v_dirname text := $3;
    v_srcpath text;
    v_dstpath text;
    v_linked_url text;
    v_datalink datalink;
    v_token uuid;
BEGIN
    -- This function can only be used in an UPDATE statement
    IF regexp_match(current_query(), '[,\(]\s*dlvalue', 'i') IS NOT NULL THEN
        RAISE EXCEPTION 'Use of dlvalue(datalink, uri, text, text) in an insert statement is not authorized.';
    END IF;

    -- If data location is NULL returns NULL
    IF $2 IS NULL THEN
        RETURN NULL;
    END IF;

    -- Set comment
    IF v_comment IS NULL AND $1 IS NOT NULL THEN
        SELECT ($1).dl_comment INTO v_comment;
    END IF;

    -- If the datalink is null or the url is empty just proceed like an insert statement
    -- Add the true value at end to notice dlvalue() for insert to not check the statement.
    IF $1 IS NULL THEN

        -- Set default directory as it can be NULL, set it to FILE if this is not a well defined URL
        SELECT dl_default_linktype($2) INTO v_dirname;
        IF v_dirname IS NULL THEN
            RAISE EXCEPTION 'No default base directory found corresponding to this URL.';
        END IF;
    
        -- Get options for this directory
        SELECT * INTO v_directory FROM dl_directory_base(v_dirname);
    
        -- If the URL is an empty string return a datalink with an zero length uri
        IF $2 = '' THEN
            -- Construct the datalink that will be returned
            SELECT v_directory.dirid, ''::uri, v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
            RETURN v_datalink;
        END IF;
    END IF;

    -- Set directory from updated datalink as the parameter value can be NULL
    IF v_dirname IS NULL THEN
        -- Get directory name from updated datalink
       SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    END IF;

    -- Get options for this directory
    SELECT * INTO v_directory FROM dl_directory_base(v_dirname);

    -- If the URL is an empty string return a datalink with an zero length uri
    IF $2 = '' THEN
        SELECT '' INTO v_uri;
        -- Construct the datalink that will be returned
        SELECT v_directory.dirid, '', v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
        RETURN v_datalink;
    END IF;

    -- With DLVALUE a token in URL is not used, shall be removed
    SELECT remove_token_from_url($2) INTO v_uri;

    -- Rebase URL following the directory base URL
    SELECT base INTO v_base FROM pg_datalink_bases WHERE dirid = v_directory.dirid;
    IF FOUND THEN
        SELECT uri_get_str(uri_rebase_url(v_uri, v_base)) INTO v_uri;
    ELSE
        -- This should not happen as the base column has a NOT NULL constraint
        RAISE EXCEPTION 'No base found for directory "%" when rebasing URI %', v_directory.dirid, $2;
    END IF;

    -- Check that the scheme is 'file' or 'http' otherwise throw an error
    IF uri_get_scheme(v_uri) != 'file' AND uri_get_scheme(v_uri) != 'http' THEN
        RAISE EXCEPTION 'Invalid uri "%" for datalink, only file:// or http:// schemes are supported', v_uri;
    END IF;

    -- Now check that the URI has the same directory base
    IF regexp_matches(v_uri::text, '^'||v_base::text) IS NOT NULL THEN
        SELECT uri_get_path(v_uri) INTO v_srcpath;
        -- With NO LINK CONTROL just set new datalink value and return
        IF NOT v_directory.linkcontrol THEN
            SELECT v_directory.dirid, dl_relative_path(v_uri, v_directory.base), v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
            RETURN v_datalink;
        END IF;
        -- Check that we have write permission
        IF v_directory.writeperm THEN
            -- With FILE LINK CONTROL be sure that file exists on filesystem
            IF NOT uri_path_exists(v_srcpath::uri) THEN
                 RAISE EXCEPTION 'DataLink file "%" must exists on filesystem.', v_srcpath;
            END IF;
            -- If the file is a symlink get the target file and
            -- extract the token from the file to save it
            IF datalink_is_symlink(v_srcpath) THEN
                SELECT datalink_symlink_target(v_srcpath) INTO v_dstpath;
                -- Get the token from inside the target file path
                SELECT (regexp_match(v_dstpath, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                IF v_token IS NULL THEN
                    SELECT (regexp_match(v_dstpath, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                END IF;
            ELSE
                -- Get the token from inside the target file path
                SELECT (regexp_match(v_dstpath, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                IF v_token IS NULL THEN
                    SELECT (regexp_match(v_dstpath, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                END IF;
            END IF;
            -- With a new file without token genere one and rename the file with a token
            IF v_token IS NULL THEN
                -- Create a symlink with the token for reading to allow access to the target file
                SELECT uuid_generate_v4() INTO v_token;
                SELECT add_token_to_url(v_srcpath, v_token::text) INTO v_dstpath;
                -- Rename the file with its token
                SELECT datalink_rename_localfile(v_srcpath, v_dstpath) INTO v_ret;
                IF NOT v_ret THEN
                    RAISE EXCEPTION 'can not rename file "%" into "%"', v_srcpath, v_dstpath;
                END IF;
            END IF;
            -- Construct the datalink that will be returned and move old token to dl_re_token column
            SELECT v_directory.dirid, dl_relative_path(v_uri, v_directory.base), v_comment, v_token, ($1).dl_token INTO v_datalink;
        ELSE
            RAISE EXCEPTION 'No write permission to file "%"', v_uri;
        END IF;
    ELSE
        RAISE EXCEPTION 'DataLink URL "%" does not match directory base "%"', v_uri, v_base;
    END IF;

    -- Store archive information if RECOVERY YES attribute is set
    IF v_directory.recovery THEN
	INSERT INTO pg_datalink_archives VALUES (v_directory.dirid, dl_url_rebase(v_uri, v_directory.dirid)) ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_datalink;
END
$$ LANGUAGE plpgsql;

--  Overload dlvalue function to allow no comment in parameters
CREATE FUNCTION dlvalue(datalink, uri, text) RETURNS datalink AS $$
    SELECT dlvalue($1, $2, $3, NULL::text);
$$ LANGUAGE SQL;

--  Overload dlvalue function to allow directory and no comment in parameters
CREATE FUNCTION dlvalue(datalink, uri) RETURNS datalink AS $$
    SELECT dlvalue($1, $2, NULL::text, NULL::text);
$$ LANGUAGE SQL;

--  Overload dlvalue function to create an empty Datalink just with a comment
CREATE FUNCTION dlvalue(datalink, text) RETURNS datalink AS $$
    SELECT dlvalue($1, ''::uri, NULL::text, $2);
$$ LANGUAGE SQL;

-- SQL/MED functions
-- The DLVALUE function returns a DataLink value for INSERT statement. As it
-- can only be used to insert new entry we do not need to register a token.
-- DLVALUE(data-location, directory-name, comment)
CREATE FUNCTION dlvalue(uri, text, text) RETURNS datalink AS $$
DECLARE
    v_directory record;
    v_base uri;
    v_uri uri;
    v_comment text := $3;
    v_dirname text := $2;
    v_srcpath text;
    v_dstpath text;
    v_datalink datalink;
    v_token uuid;
    v_ret boolean;
BEGIN
    -- This function can only be used in an INSERT statement
    IF regexp_match(current_query(), '=\s*dlvalue', 'i') IS NOT NULL THEN
        RAISE EXCEPTION 'Use of dlvalue(uri, text, text) in an update statement is not authorized, use the dlvalue(datalink, uri, text, text) form instead.';
    END IF;

    -- If data location is NULL returns NULL
    IF $1 IS NULL THEN
        RETURN NULL;
    END IF;

    -- Set default directory as it can be NULL, set it to FILE if this is not a well defined URL
    IF v_dirname IS NULL THEN
        SELECT dl_default_linktype($1) INTO v_dirname;
        IF v_dirname IS NULL THEN
            RAISE EXCEPTION 'No directory found corresponding to this URI, this is not authorized.';
        END IF;
    END IF;

    -- Get options for this directory
    SELECT * INTO v_directory FROM dl_directory_base(v_dirname);

    -- If the URL is an empty string return a datalink with an zero length uri
    IF $1 = '' THEN
        -- Construct the datalink that will be returned
        SELECT v_directory.dirid, ''::uri, v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
    ELSE
        -- Rebase URL following the directory base URL
        SELECT uri_get_str(uri_rebase_url($1, v_directory.base)) INTO v_uri;

	-- Check that the scheme is 'file' or 'http' otherwise throw an error
	IF uri_get_scheme(v_uri) != 'file' AND uri_get_scheme(v_uri) != 'http' THEN
	     RAISE EXCEPTION 'Invalid uri "%" for datalink, only file:// or http:// schemes are supported', v_uri;
	END IF;

        -- Now be sure that the URI has the same directory base to continue the work
        IF regexp_matches(v_uri::text, '^'||v_directory.base::text) IS NOT NULL THEN
            SELECT uri_get_path(v_uri) INTO v_srcpath;
            -- With NO LINK CONTROL just set new datalink value and return
            IF NOT v_directory.linkcontrol THEN
                SELECT v_directory.dirid, dl_relative_path(v_uri, v_directory.base), v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
                RETURN v_datalink;
            END IF;
            -- Check that we have write permission
            IF v_directory.writeperm THEN
                -- With FILE LINK CONTROL be sure that file exists on filesystem
                IF NOT uri_path_exists(v_srcpath::uri) THEN
                     RAISE EXCEPTION 'DataLink file "%" must exists on filesystem.', v_srcpath;
                END IF;
                
                -- If the file is a symlink get the target file and
                -- extract the token from the file to save it
                IF datalink_is_symlink(v_srcpath) THEN
                    SELECT datalink_symlink_target(v_srcpath) INTO v_dstpath;
                    -- Get the token from inside the target file path
                    SELECT (regexp_match(v_dstpath, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                    IF v_token IS NULL THEN
                        SELECT (regexp_match(v_dstpath, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                    END IF;
                ELSE
                    -- Get the token from inside the target file path
                    SELECT (regexp_match(v_srcpath, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                    IF v_token IS NULL THEN
                        SELECT (regexp_match(v_srcpath, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_token;
                    END IF;
                    -- With a new file without token genere one and rename the file with a token
                    IF v_token IS NULL AND v_directory.writetoken THEN
                        -- Create a symlink with the token for reading to allow access to the target file
                        SELECT uuid_generate_v4() INTO v_token;
                        SELECT add_token_to_url(v_srcpath, (v_token)::text) INTO v_dstpath;
                        -- Rename the file with its token
                        SELECT datalink_rename_localfile(v_srcpath, v_dstpath) INTO v_ret;
                        IF NOT v_ret THEN
                            RAISE EXCEPTION 'can not rename file "%" into "%"', v_srcpath, v_dstpath;
                        END IF;
                    END IF;
                END IF;
                -- Remove token from url
                SELECT remove_token_from_url(uri_get_path(v_uri)::uri) INTO v_uri;
                -- Construct the datalink that will be returned we don't use token for insert
                SELECT v_directory.dirid, dl_relative_path(v_uri, v_directory.base), v_comment, v_token, NULL::uuid INTO v_datalink;
            ELSE
                RAISE EXCEPTION 'No write permission to file "%"', v_uri;
            END IF;
        ELSE
            RAISE EXCEPTION 'DataLink URL "%" does not match directory base "%"', v_uri, v_directory.base;
        END IF;
    END IF;

    -- Store archive information if RECOVERY YES attribute is set
    IF v_directory.recovery THEN
	INSERT INTO pg_datalink_archives VALUES (v_directory.dirid, dl_url_rebase(v_uri, v_directory.dirid)) ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_datalink;
END
$$ LANGUAGE plpgsql;

--  Overload dlvalue function to allow no comment in parameters
CREATE FUNCTION dlvalue(uri, text) RETURNS datalink AS $$
    SELECT dlvalue($1, $2, NULL::text);
$$ LANGUAGE SQL;

--  Overload dlvalue function to allow directory and no comment in parameters
CREATE FUNCTION dlvalue(uri) RETURNS datalink AS $$
    SELECT dlvalue($1, NULL::text, NULL::text);
$$ LANGUAGE SQL;

--  Overload dlvalue function to create an empty Datalink just with a comment
CREATE FUNCTION dlvalue(text) RETURNS datalink AS $$
    SELECT dlvalue(''::uri, NULL::text, $1);
$$ LANGUAGE SQL;


-- The DLNEWCOPY function returns a Datalink value which has an attribute
-- indicating that the referenced file has changed. The datalink value returned
-- by DLNEWCOPY indicates to the SQL-server that the content of the file, referenced
-- by that datalink, is different (i.e., the content has changed, but not the URL)
-- from what was previously referenced by the datalink.
-- As we can not obtain obtain the datalink impacted by the update in
-- plpgsql this function received the mofified datalink at first argument.
-- DLNEWCOPY(datalink, data-location, hasToken)
CREATE OR REPLACE FUNCTION dlnewcopy(datalink, uri, boolean) RETURNS datalink AS $$
DECLARE
    v_directory record;
    v_uri uri;
    v_pathorig text;
    v_ret boolean;
    v_token uuid;
    v_datalink datalink;
BEGIN
    -- dlnewcopy() can only be used in UPDATE statement
    IF regexp_match(current_query(), '=\s*dlnewcopy', 'i') IS NULL THEN
        RAISE EXCEPTION 'Function dlnewcopy() can only be called in an UPDATE statement.';
    END IF;

    -- Return NULL is the datalink is NULL
    IF $1 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to datalink constructor.';
    END IF;
    -- Return NULL is the data location is NULL
    IF $2 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to data location.';
    END IF;
    -- The token indication can not be null
    IF $3 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to token indication.';
    END IF;

    -- Get default base directory
   SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);

    -- With NO LINK CONTROL we have nothing to do here
    IF NOT v_directory.linkcontrol THEN
        RAISE EXCEPTION 'The Datalink has the NO LINK CONTROL, writing is not authorized.';
    END IF;

    -- If the URI has the token inside verify that it is well formed
    IF $3 THEN
        -- Get the token from inside the uri
        SELECT verify_token_from_uri($2, true) INTO v_token;
        -- and remove it from the uri
        SELECT remove_token_from_url($2) INTO v_uri;
    ELSE
        -- When the datalink do not require a token for writing, the URL must have the '.new' suffix
        IF NOT v_directory.writetoken THEN
            SELECT (regexp_match($2::text, '^.*.new$'))[1] INTO v_uri;
            IF v_uri IS NULL THEN
                RAISE EXCEPTION 'when NOT REQUIRING TOKEN FOR UPDATE the new URL must have the ".new" suffix.';
            END IF;
        ELSE
            -- A token is mandatory
            RAISE EXCEPTION 'the Datalink has the REQUIRING TOKEN FOR UPDATE attribute, a token for writing is mandatory.';
        END IF;
    END IF;

    -- Rebase the URL with the directory base
    SELECT uri_get_str(uri_rebase_url(v_uri, v_directory.base)) INTO v_uri;

    -- Verify that both old and new URI are the same without token
    IF dlurlcompleteonly($1) != v_uri::text AND dlurlcompleteonly($1)||'.new' != v_uri::text THEN
        IF v_directory.writetoken THEN
            RAISE EXCEPTION 'URI are not the same "%s" to "%s"', dlurlcompleteonly($1), v_uri;
        ELSE
            RAISE EXCEPTION 'URI are not the same "%s" to "%s"', dlurlcompleteonly($1)||'.new', v_uri;
        END IF;
    END IF;

    -- Check that we have write permission
    IF v_directory.writeperm THEN
        -- Get path of the original file without token to work on the symlink only
        SELECT dlurlpathonly($1) INTO v_pathorig;

        -- Get full filename on disk with the token of the new file
        SELECT uri_get_str(uri_rebase_url($2, v_directory.base)) INTO v_uri;

        -- Verify that the new file exists it must have been
        -- created by DLURLCOMPLETEWRITE or DLURLPATHWRITE
        IF NOT uri_path_exists(v_uri) THEN
            RAISE EXCEPTION 'Data location source file "%" must exists on filesystem.', v_uri;
        END IF;

        -- When no token is require just rename origin file with the .old extension
        -- and rename new file by removing the .new extension to the original name.
        IF NOT v_directory.writetoken THEN
            -- Rename current file with the old suffix so that it can be restored using dlpreviouscopy
            SELECT datalink_rename_localfile(v_pathorig, v_pathorig||'.old') INTO v_ret;
            IF NOT v_ret THEN
                RAISE EXCEPTION 'can not rename new file "%" into "%"', v_pathorig, v_pathorig||'.old';
            END IF;
            -- Rename new file with the .new suffix into the original name
            SELECT datalink_rename_localfile(v_pathorig||'.new', v_pathorig) INTO v_ret;

            -- Return the datalink without token
            SELECT ($1).dl_base, dl_relative_path(($1).dl_path, v_directory.base), ($1).dl_comment, NULL::uuid, NULL::uuid INTO v_datalink;
        ELSE
            -- Return the datalink with the new tokens
            SELECT ($1).dl_base, dl_relative_path(($1).dl_path, v_directory.base), ($1).dl_comment, v_token, ($1).dl_token INTO v_datalink;
        END IF;
    ELSE
        -- No write permission
        RAISE EXCEPTION 'No write permission on directory "%".', v_directory.dirname;
    END IF;

    -- Store archive information if RECOVERY YES attribute is set
    IF v_directory.recovery THEN
	INSERT INTO pg_datalink_archives VALUES (($1).dl_base, dl_url_rebase(($1).dl_path, ($1).dl_base)) ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_datalink;
END
$$ LANGUAGE plpgsql;

-- The DLPREVIOUSCOPY function returns a Datalink value which has an attribute
-- indicating that the referenced file has changed.
-- As we can not obtain obtain the datalink impacted by the update in
-- plpgsql this function received the mofified datalink at first argument.
-- DLPREVIOUSCOPY(datalink, data-location, hasToken)
CREATE OR REPLACE FUNCTION dlpreviouscopy(datalink, uri, boolean) RETURNS datalink AS $$
DECLARE
    v_directory record;
    v_uri uri;
    v_path text;
    v_pathorig text;
    v_ret boolean;
    v_datalink datalink;
BEGIN
    -- dlpreviouscopy() can only be used in UPDATE statement
    IF regexp_match(current_query(), '=\s*dlpreviouscopy', 'i') IS NULL THEN
        RAISE EXCEPTION 'Function dlpreviouscopy() can only be called in an UPDATE statement.';
    END IF;

    -- Return NULL is the datalink is NULL
    IF $1 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to datalink constructor.';
    END IF;
    -- Return NULL is the data location is NULL
    IF $2 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to data location.';
    END IF;
    -- The token indication can not be null
    IF $3 IS NULL THEN
        RAISE EXCEPTION 'null argument passed to token indication.';
    END IF;

    -- Get default base directory
   SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);

    -- With NO LINK CONTROL we have nothing to do here
    IF NOT v_directory.linkcontrol THEN
        RAISE EXCEPTION 'The Datalink has the NO LINK CONTROL, writing is not authorized.';
    END IF;

    -- If the URI has the token inside verify that it is well formed and valid
    IF $3 THEN
        -- Get the token from inside the uri
        PERFORM verify_token_from_uri($2, true);
        -- and remove it from the uri
        SELECT remove_token_from_url($2) INTO v_uri;
        -- Raise an error if there is not previous token and no .old file exists
        IF ($1).dl_prev_token IS NULL THEN
            -- Verify that there is a .old file, if it exists this is the original file to be restored
            IF NOT uri_path_exists((v_uri::text||'.old')::uri) THEN
                RAISE EXCEPTION 'no previous datalink to restore.';
            END IF;
        END IF;
    ELSE
        -- When the datalink do not require a token for writing, the URL must have the '.new' suffix
        IF NOT v_directory.writetoken THEN
            SELECT (regexp_match($2::text, '^.*.old$'))[1] INTO v_uri;
            IF v_uri IS NULL THEN
                RAISE EXCEPTION 'when NOT REQUIRING TOKEN FOR UPDATE the previous URL must have the ".old" suffix.';
            END IF;
        ELSE
            -- A token is mandatory
            RAISE EXCEPTION 'the Datalink hes the REQUIRING TOKEN FOR UPDATE attribute, a token for writing is mandatory.';
        END IF;
    END IF;

    -- Rebase the URL with the directory base
    SELECT uri_get_str(uri_rebase_url(v_uri, v_directory.base)) INTO v_uri;

    -- Verify that both old and new URI are the same without token
    IF dlurlcompleteonly($1) != v_uri::text AND dlurlcompleteonly($1)||'.old' != v_uri::text THEN
        IF v_directory.writetoken THEN
            RAISE EXCEPTION 'URI are not the same "%s" to "%s, can not restore previous version"', dlurlcompleteonly($1), v_uri;
        ELSE
            RAISE EXCEPTION 'URI are not the same "%s" to "%s, can not restore previous version"', dlurlcompleteonly($1)||'.old', v_uri;
        END IF;
    END IF;

    -- Check that we have write permission
    IF v_directory.writeperm THEN

        -- Get path of the original file without token to work on the symlink only
        SELECT dlurlpathonly($1) INTO v_pathorig;

        -- Get full filename on disk with the token of the new file
        SELECT uri_get_str(uri_rebase_url($2, v_directory.base)) INTO v_uri;

        -- Verify that the new file exists it must have been
        -- created by DLURLCOMPLETEWRITE or DLURLPATHWRITE
        IF NOT uri_path_exists(v_uri) THEN
            RAISE EXCEPTION 'Data location source file "%" must exists on filesystem.', v_uri;
        END IF;

        -- When no token is require just rename file with the .old extension into
        -- the original name after removing the original file.
        IF NOT v_directory.writetoken THEN
            -- Rename .old file into the original name
            SELECT datalink_rename_localfile(v_pathorig||'.old', v_pathorig) INTO v_ret;
            IF NOT v_ret THEN
                RAISE EXCEPTION 'can not rename old file "%" into "%"', v_pathorig||'.old', v_pathorig;
            END IF;

            -- Return the datalink without token
            SELECT ($1).dl_base, dl_relative_path(($1).dl_path, v_directory.base), ($1).dl_comment, NULL::uuid, NULL::uuid INTO v_datalink;

        ELSE

            -- Set link target from the previous token or from the .old file if dl_prev_token is null
            IF ($1).dl_prev_token IS NULL THEN
                -- Set target to .old file
                SELECT (v_pathorig||'.old') INTO v_path;
            ELSE
                -- Add old token to the url to relink to this file
                SELECT add_token_to_url(v_pathorig, ($1.dl_prev_token)::text) INTO v_path;
            END IF;

            -- Verify that the path to previous file exists
            IF NOT uri_path_exists(v_path::uri) THEN
                RAISE EXCEPTION 'Data location of previous file "%" must exists on filesystem.', v_path;
            END IF;
            -- Recreate symlink to the previous linked file if this is not a first copy
            IF ($1).dl_prev_token IS NOT NULL THEN
                SELECT datalink_relink_localfile(uri_get_path(v_pathorig::uri), uri_get_path(v_path)) INTO v_ret;
                IF NOT v_ret THEN
                    RAISE EXCEPTION 'can not relink "%s" to "%s"', v_pathorig, v_path;
                END IF;
            ELSE
                -- Override the link with the .old file
                SELECT datalink_rename_localfile(v_path, v_pathorig) INTO v_ret;
                IF NOT v_ret THEN
                    RAISE EXCEPTION 'can not rename "%s" to "%s"', v_path, v_pathorig;
                END IF;
            END IF;

	    -- Unlink the copy as it is no more referenced.
            IF ($1).dl_token IS NOT NULL THEN
		-- RAISE NOTICE 'removing copy file "%" after call to dlpreviouscopy()', v_uri;
                SELECT datalink_unlink_localfile(v_uri::uri) INTO v_ret;
            END IF;

            -- Replace replace previous token by NULL and current token by previous one
            SELECT ($1).dl_base, dl_relative_path(($1).dl_path, v_directory.base), ($1).dl_comment, $1.dl_prev_token, NULL::uuid INTO v_datalink;

        END IF;

    ELSE
        -- No write permission
        RAISE EXCEPTION 'No write permission on directory "%".', v_directory.dirname;
    END IF;

    RETURN v_datalink;
END
$$ LANGUAGE plpgsql;

-- The DLURLCOMPLETE function returns the complete URL value from
-- a DataLink value with a token for reading. 
-- DLURLCOMPLETE(DataLink)
CREATE FUNCTION dlurlcomplete(datalink) RETURNS text AS $$
DECLARE
    v_url text;
    v_srcurl text;
    v_dstpath text;
    v_srcpath text;
    v_token uuid := NULL;
    v_directory record;
    v_ret boolean;
BEGIN
    -- Return a zero length string if the URI is empty
    IF ($1).dl_path = '' THEN
        RETURN '';
    END IF;

    -- Get directory base information
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    -- Get the path to current file
    SELECT uri_rebase_url(dlurlpathonly($1)::uri, v_directory.base) INTO v_srcurl;

    -- Add a new token to the URL if we have READ PERMISSION DB.
    -- If we get there the user has SELECT priviledge on the table.
    IF v_directory.readperm THEN
        -- Add the current datalink token to this path that will be use as symlink target
        IF ($1).dl_token IS NOT NULL THEN
            SELECT add_token_to_url(v_srcurl::text, (($1).dl_token)::text) INTO v_dstpath;
        ELSE
            v_dstpath := v_srcurl;
        END IF;
        -- We can not create symlink for a remote URL for the moment
        IF uri_get_scheme(v_srcurl::uri) != 'file' THEN
            RAISE EXCEPTION 'can not link remote URI "%"',  v_srcurl;
        ELSE
            -- Verify that the file exist
            IF NOT uri_path_exists(v_dstpath::uri) THEN
                RAISE EXCEPTION 'file "%" does not exists', v_dstpath;
            END IF;
        END IF;
        SELECT uuid_generate_v4() INTO v_token;
        SELECT add_token_to_url(v_srcurl, (v_token)::text) INTO v_url;
        -- Store the token internally for later access validation, the
        -- application will need this token in the url to access the file
        SELECT datalink_register_readtoken(v_url) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'can not register a token for URI "%"',  v_url;
        END IF;
        -- Create a symlink with the token for reading to allow access to the target file
        SELECT datalink_createlink_localfile(uri_get_path(uri_rebase_url(v_url::uri, v_directory.base)), uri_get_path(v_dstpath::uri)) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'can not create symlink "%" to "%"', uri_get_path(uri_rebase_url(v_url::uri, v_directory.base)), v_dstpath;
        END IF;
    ELSE
        RETURN v_srcurl;
    END IF;

    RETURN v_url;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLURLCOMPLETEWRITE function returns the complete URL value from
-- a DataLink value with a token for writing. The file is locked and
-- copied with the token in its name, next work will be done on it.
-- The file must be on a local filesystem, there is no remote implementation.
-- DLURLCOMPLETEWRITE(DataLink)
CREATE FUNCTION dlurlcompletewrite(datalink) RETURNS text AS $$
DECLARE
    v_srcurl text;
    v_srcpath text;
    v_dsturl text;
    v_ret boolean;
    v_token uuid;
    v_directory record;
BEGIN
    -- Return a zero length string if the URI is empty
    IF ($1).dl_path = '' THEN
        RETURN '';
    END IF;

    -- Get directory base informtion
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);

    -- When the DB has no control to the file write is not possible
    IF NOT v_directory.linkcontrol THEN
        RAISE EXCEPTION 'Can not write with NO LINK CONTROL.';
    END IF;

    -- Get the full URL of the file
    SELECT uri_rebase_url(dlurlcompleteonly($1)::uri, v_directory.base) INTO v_srcurl;

    -- If we have WRITE PERMISSION ADMIN
    IF v_directory.writeperm THEN
        -- Add the current datalink token to this path that will be use as symlink target
        IF ($1).dl_token IS NOT NULL THEN
            SELECT add_token_to_url(v_srcurl, (($1).dl_token)::text) INTO v_srcpath;
        ELSE
            v_srcpath := v_srcurl;
        END IF;

        -- Check that we can write to this file
        IF uri_get_scheme(v_srcurl::uri) != 'file' THEN
            RAISE EXCEPTION 'can not write to a remote URL "%"', v_srcurl;
        END IF;
        IF NOT uri_path_exists(v_srcpath::uri) THEN
            RAISE EXCEPTION 'file "%" does not exists', v_srcpath;
        END IF;

        -- When the datalink do not require a token for writing, just return the URL with the '.new' suffix
        IF NOT v_directory.writetoken THEN
            SELECT v_srcurl||'.new' INTO v_dsturl;
        ELSE
            -- Get new token
            SELECT uuid_generate_v4() INTO v_token;
            -- Get URL with a new token
            SELECT add_token_to_url(v_srcurl, (v_token)::text) INTO v_dsturl;
        END IF;

        -- Now copy the file with locking the source file in non blocking mode during the copy
        SELECT datalink_copy_localfile(uri_get_path(v_srcpath::uri), uri_get_path(v_dsturl::uri)) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'Can not copy file % into %.', v_srcpath, v_dsturl;
        END IF;

        -- Store the token for later validation
        IF v_directory.writetoken THEN
            SELECT datalink_register_writetoken(v_dsturl) INTO v_ret;
            IF NOT v_ret THEN
                RAISE EXCEPTION 'can not register a token';
            END IF;
        END IF;
    ELSE
        -- Return the URL without token, WRITE PERMISSION option not ADMIN
        RETURN v_srcurl;
    END IF;

    -- Return the new URL with the token
    RETURN v_dsturl;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLURLPATH function returns the path and file name necessary to access
-- a file from a DataLink value with a token for reading.
-- DLURLPATH(Datalink)
CREATE FUNCTION dlurlpath(datalink) RETURNS text AS $$
DECLARE
    v_srcurl uri;
    v_path text;
    v_srcpath text;
    v_dstpath text;
    v_token uuid;
    v_directory record;
    v_ret boolean;
BEGIN
    -- Return a zero length string if the URI is empty
    IF ($1).dl_path = '' THEN
        RETURN '';
    END IF;

    -- Get directory base informtion
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    -- Rebase the URL
    SELECT uri_rebase_url(dlurlpathonly($1)::uri, v_directory.base) INTO v_srcurl;
    -- Extract the path
    SELECT uri_get_path(v_srcurl) INTO v_srcpath;

    -- Add a new token to the URL if we have READ PERMISSION DB
    IF v_directory.readperm THEN
        -- Add the current datalink token to this path that will be use as symlink target
        IF ($1).dl_token IS NOT NULL THEN
            SELECT add_token_to_url(v_srcurl::text, (($1).dl_token)::text) INTO v_dstpath;
        ELSE
            v_dstpath := v_srcurl;
        END IF;
        -- We can not create symlink for a remote URL for the moment
        IF uri_get_scheme(v_srcurl::uri) != 'file' THEN
            RAISE EXCEPTION 'can not link remote URI "%"',  v_srcurl;
        END IF;
        -- Verify that the file exist
        IF NOT uri_path_exists(v_dstpath::uri) THEN
            RAISE EXCEPTION 'file "%" does not exists', v_dstpath;
        END IF;

        -- Get new token
        SELECT uuid_generate_v4() INTO v_token;
        -- Get path with a new token
        SELECT add_token_to_url(v_srcpath, (v_token)::text) INTO v_path;
        -- Store the token for later validation
        SELECT datalink_register_readtoken(v_path) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'can not register a token for URI "%"', v_path;
        END IF;
        -- Create a symlink with the token for reading
        SELECT datalink_createlink_localfile(uri_get_path(v_path::uri), uri_get_path(v_dstpath::uri)) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'can not create symlink "%" to "%"', v_path, v_dstpath;
        END IF;
    ELSE
        RETURN v_srcpath;
    END IF;

    RETURN v_path;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLURLPATHWRITE function returns the full path to a linked file
-- with a token for writing. The file is locked and copied with the
-- token in its name, next work will be done on it.
-- DLURLPATHWRITE(Datalink)
CREATE FUNCTION dlurlpathwrite(datalink) RETURNS text AS $$
DECLARE
    v_srcurl text;
    v_srcpath text;
    v_dstpath text;
    v_ret boolean;
    v_token uuid;
    v_directory record;
BEGIN
    -- Return a zero length string if the URI is empty
    IF ($1).dl_path = '' THEN
        RETURN '';
    END IF;

    -- Get directory base informtion
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);

    -- When the DB has no control to the file write is not possible
    IF NOT v_directory.linkcontrol THEN
        RAISE EXCEPTION 'Can not write with NO LINK CONTROL.';
    END IF;

    -- Get the full URL of the file
    SELECT uri_rebase_url(dlurlcompleteonly($1)::uri, v_directory.base) INTO v_srcurl;
    -- and the path
    SELECT uri_rebase_url(dlurlpathonly($1)::uri, v_directory.base) INTO v_dstpath;

    -- Add a new token to the URL if we have WRITE PERMISSION ADMIN
    IF v_directory.writeperm THEN
        -- Add the current datalink token to this path that will be use as symlink target
        IF ($1).dl_token IS NOT NULL THEN
            SELECT add_token_to_url(v_dstpath::text, (($1).dl_token)::text) INTO v_srcpath;
        END IF;
        -- We can not create link for a remote URL for the moment
        IF uri_get_scheme(v_srcurl::uri) != 'file' THEN
            RAISE EXCEPTION 'can not link remote URI "%"',  v_srcurl;
        END IF;
        -- Verify that the file exist
        IF NOT uri_path_exists(v_srcpath::uri) THEN
            RAISE EXCEPTION 'file "%" does not exists', v_srcpath;
        END IF;

        -- When the datalink do not require a token for writing, just return the URL with the '.new' suffix
        IF NOT v_directory.writetoken THEN
            SELECT v_srcpath||'.new' INTO v_dstpath;
        ELSE
            -- Get new token
            SELECT uuid_generate_v4() INTO v_token;
            -- Get URL with a new token
            SELECT add_token_to_url(v_dstpath, (v_token)::text) INTO v_dstpath;
        END IF;
        -- Now copy the file with locking the source file in non blocking mode during the copy
        SELECT datalink_copy_localfile(uri_get_path(v_srcpath::uri), uri_get_path(v_dstpath::uri)) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'Can not copy file % into %.', uri_get_path(v_srcpath::uri), uri_get_path(v_dstpath::uri);
        END IF;
        -- Store the token for later validation
        IF v_directory.writetoken THEN
            SELECT datalink_register_writetoken(v_dstpath) INTO v_ret;
            IF NOT v_ret THEN
                RAISE EXCEPTION 'can not register a token';
            END IF;
        END IF;
    END IF;

    -- Return the new URL with or without the token
    RETURN v_dstpath;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLREADFILE function returns a bytea representing the content
-- of a DataLink file value.
-- The linked file is shared locked when reading in the
-- internal function read_binary_file() from datalink.c.
-- DLREADFILE(DataLink, Uri-with-token)
CREATE FUNCTION dlreadfile(datalink, uri) RETURNS bytea AS $$
DECLARE
    v_uri uri;
    v_orig uri;
    v_path text;
    v_content bytea;
    v_token uuid;
    v_directory record;
BEGIN

    -- Return NULL is the datalink has no URL
    IF ($1).dl_path = '' THEN
        RAISE EXCEPTION 'the datalink to read has no URL.';
    END IF;

    -- Get default base directory
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    -- With NO LINK CONTROL we have nothing to do here
    IF NOT v_directory.linkcontrol OR NOT v_directory.readperm THEN
        RAISE EXCEPTION 'reading URL "%" is not authorized.', ($1).dl_path;
    END IF;

    -- Rebase the URL with the directory base
    SELECT uri_get_str(uri_rebase_url($2, v_directory.base)) INTO v_uri;

    -- We must have a token inside the URL verify it
    SELECT verify_token_from_uri(v_uri, false) INTO v_token;
    IF v_token IS NULL THEN
        RAISE EXCEPTION 'access denied to URI "%".', $2;
    END IF;
    -- Verify that we have the same directory base
    IF regexp_matches(v_uri::text, '^'||(v_directory.base)::text) IS NULL THEN
        RAISE EXCEPTION 'URI "%" does not match directory base "%"', v_uri, v_directory.base;
    END IF;

    -- Get the full path of the target file
    SELECT uri_get_path(v_uri) INTO v_path;

    -- Get the content of the file as a bytea
    SELECT datalink_read_localfile(v_path, 0, -1) INTO v_content;

    RETURN v_content;
END
$$ LANGUAGE plpgsql STRICT;

-- The DLWRITEFILE function write a bytea to a linked file.
-- The linked file is exclusively locked when writing in
-- internal function datalink_write_localfile().
-- DLRWRITEFILE(DataLink, Uri-with-token, Bytea)
CREATE FUNCTION dlwritefile(datalink, uri, bytea) RETURNS boolean AS $$
DECLARE
    v_uri uri;
    v_orig uri;
    v_path text;
    v_ret boolean;
    v_token uuid;
    v_directory record;
BEGIN

    -- Return NULL is the datalink has not URL
    IF ($1).dl_path = '' THEN
        RAISE EXCEPTION 'the datalink to write has no URL.';
    END IF;

    -- Get default base directory
    SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    -- With NO LINK CONTROL we have nothing to do here
    IF NOT v_directory.linkcontrol OR NOT v_directory.writeperm THEN
        RAISE EXCEPTION 'writing to URL "%" is not authorized.', ($1).dl_path;
    END IF;

    -- Rebase the URL with the directory base
    SELECT uri_get_str(uri_rebase_url($2, v_directory.base)) INTO v_uri;

    -- We must have a token inside the URL verify it
    SELECT verify_token_from_uri(v_uri, true) INTO v_token;
    IF v_token IS NULL THEN
        RAISE EXCEPTION 'access denied to URI "%".', $2;
    END IF;
    -- Verify that we have the same directory base
    IF regexp_matches(v_uri::text, '^'||(v_directory.base)::text) IS NULL THEN
        RAISE EXCEPTION 'URI "%" does not match directory base "%"', v_uri, v_directory.base;
    END IF;

    -- Get the full path of the target file
    SELECT uri_get_path(v_uri) INTO v_path;
    -- Write content to file
    SELECT datalink_write_localfile(v_path, $3) INTO v_ret;

    RETURN v_ret;
END
$$ LANGUAGE plpgsql;

-- The DLREPLACECONTENT function returns a DATALINK value.
-- Replacement files must reside in the same directory as the linked files.
-- NOT SUPPORTED: Replacement file names must consist of the original file
-- name plus a suffix string that can be a maximum of 20 characters.
-- With this implementation can be any URL in the same base directory.
-- As we can not obtain obtain the datalink impacted by the update in
-- plpgsql this function received the mofified datalink at first argument.
-- Should be DLREPLACECONTENT(data-location-target , data-location-source, comment)
-- DLREPLACECONTENT(datalink-target, data-location-target, data-location-source, comment)
CREATE OR REPLACE FUNCTION dlreplacecontent(datalink, uri, uri, text) RETURNS datalink AS $$
DECLARE
    v_directory record;
    v_src uri;
    v_dst uri;
    v_uri uri;
    v_srcpath text;
    v_dstpath text;
    v_datalink datalink;
    v_comment text := $4;
    v_token uuid;
    v_oldtoken uuid;
    v_ret boolean;
BEGIN
    -- Return NULL is the data location target is NULL
    IF $2 IS NULL THEN
        RETURN NULL;
    END IF;

    -- Extract directory information
    IF ($1).dl_base IS NOT NULL THEN
        -- Get directory base informtion
       SELECT * INTO v_directory FROM dl_directory_base(($1).dl_base);
    ELSE
        -- Get default base directory
        SELECT * INTO v_directory FROM dl_directory_base(((SELECT CASE WHEN uri_get_scheme($2) = '' OR uri_get_scheme($2) = 'file' THEN 'FILE' ELSE 'URL' END)::text));
    END IF;

    -- Rebase target url with the default datalink base.
    SELECT uri_rebase_url($2, v_directory.base) INTO v_dst;

    -- Rebase source url with the datalink base.
    IF $3 IS NOT NULL OR $3 != '' THEN
        SELECT uri_rebase_url($3, v_directory.base) INTO v_src;
    END IF;

    -- Set comment
    IF $4 IS NULL AND $1 IS NOT NULL THEN
        SELECT ($1).dl_comment INTO v_comment;
    END IF;

    -- Verify that we have the same URL in destination URI and in Datalink
    IF ($1).dl_path != '' AND v_dst != uri_rebase_url(($1).dl_path, v_directory.base) THEN
        RAISE EXCEPTION 'Destination URL "%" is not equal to Datalink URI "%"', v_dst, uri_rebase_url(($1).dl_path, v_directory.base);
    END IF;

    -- If data-location-source is NULL or an empty string or the same as
    -- data-location-target this is the equivalent than calling DLVALUE.
    IF $3 IS NULL OR $3 = '' OR v_src = v_dst THEN
        SELECT dlvalue(''::uri, NULL::text, v_comment) INTO v_datalink;
        RETURN v_datalink;
    END IF;

    -- With FILE LINK CONTROL verify that both files exists
    IF v_directory.linkcontrol THEN
        IF NOT uri_path_exists(v_src) THEN
            RAISE EXCEPTION 'Data location source file "%" must exists on filesystem.', v_src;
        END IF;
        IF NOT uri_path_exists(v_dst) THEN
            IF NOT uri_path_exists(add_token_to_url(v_dst::text, (($1).dl_token)::text)::uri) THEN
                RAISE EXCEPTION 'Data location target file "%" must exists on filesystem.', v_dst;
            END IF;
        END IF;
    END IF;

    -- When the datalink do not require a token for writing, the URL must have the '.new' suffix
    IF NOT v_directory.writetoken THEN
        SELECT (regexp_match(v_src::text, '^.*.new$'))[1] INTO v_uri;
        IF v_uri IS NULL THEN
            RAISE EXCEPTION 'when NOT REQUIRING TOKEN FOR UPDATE the new URL must have the ".new" suffix.';
        END IF;
    ELSE
        -- Get the token from inside the uri and verify that it is well formed
        SELECT verify_token_from_uri(v_src, true) INTO v_token;
        -- remove it from the uri
        SELECT remove_token_from_url(v_src) INTO v_uri;
    END IF;

    -- Rebase the URL with the directory base
    SELECT uri_get_str(uri_rebase_url(v_uri, v_directory.base)) INTO v_uri;

    -- Verify that both old and new URI are the same without token
    IF uri_get_str(v_dst) != v_uri::text AND uri_get_str(v_dst)||'.new' != v_uri::text THEN
        IF v_directory.writetoken THEN
            RAISE EXCEPTION 'URI are not the same "%s" to "%s"', uri_get_str(v_dst), v_uri;
        ELSE
            RAISE EXCEPTION 'URI are not the same "%s" to "%s"', uri_get_str(v_dst)||'.new', v_uri;
        END IF;
    END IF;

    -- With NO LINK CONTROL we have nothing more to do, return the datalink
    IF NOT v_directory.linkcontrol THEN
        SELECT v_directory.dirid, dl_relative_path(v_dst, v_directory.base), v_comment, NULL::uuid, NULL::uuid INTO v_datalink;
        RETURN v_datalink;
    END IF;

    -- Construct path to target file with the token
    IF ($1).dl_token IS NOT NULL THEN
        SELECT add_token_to_url(v_dst::text, (($1).dl_token)::text) INTO v_dst;
    END IF;

    -- Get the path of both URI
    SELECT uri_get_path(v_uri) INTO v_srcpath;
    SELECT uri_get_path(v_dst) INTO v_dstpath;
    IF ($1).dl_token IS NULL THEN
        -- Get token from the file to replace to be used as dl_prevtoken value if any
        SELECT (regexp_match(v_dst::text, '^.*\/([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_oldtoken;
        IF v_oldtoken IS NULL THEN
            SELECT (regexp_match(v_dst::text, '^([0-9a-f\-]+);[^\/;]+$'))[1] INTO v_oldtoken;
        END IF;
    ELSE
        v_oldtoken := ($1).dl_token;
    END IF;

    -- If writetoken is false rename old file with the .old suffix and file with .new suffix into the origin name
    IF NOT v_directory.writetoken THEN
        SELECT datalink_rename_localfile(v_dstpath, v_dstpath||'.old') INTO v_ret;
        SELECT (regexp_match(v_srcpath, '^(.*).new$'))[1] INTO v_srcpath;
        IF v_srcpath IS NULL THEN
            RAISE EXCEPTION 'can not find valid source file for replacement in "%"', v_src;
        END IF;
        SELECT datalink_rename_localfile(v_srcpath||'.new', v_srcpath) INTO v_ret;
        IF NOT v_ret THEN
            RAISE EXCEPTION 'can not rename new file "%" into "%"', v_srcpath||'.new', v_dstpath;
        END IF;
        SELECT v_directory.dirid, dl_relative_path(v_dst, v_directory.base), v_comment, v_token, v_oldtoken INTO v_datalink;
    ELSE
        -- When writetoken is enable we just have to set current token pointing to the new file
        SELECT v_directory.dirid, dl_relative_path(remove_token_from_url(v_dst), v_directory.base), v_comment, v_token, v_oldtoken INTO v_datalink;
    END IF;

    -- Store archive information if RECOVERY YES attribute is set
    IF v_directory.recovery THEN
	INSERT INTO pg_datalink_archives VALUES (v_directory.dirid, dl_url_rebase(($1).dl_path, v_directory.dirid)) ON CONFLICT DO NOTHING;
    END IF;

    -- Return the datalink updated
    RETURN v_datalink;
END
$$ LANGUAGE plpgsql;

-- Overload DLREPLACECONTENT() function to allow call without comment
CREATE OR REPLACE FUNCTION dlreplacecontent(datalink, uri, uri) RETURNS datalink AS $$
        SELECT dlreplacecontent($1, $2, $3, NULL::text);
$$ LANGUAGE SQL STRICT;

-- Overload DLREPLACECONTENT() function to respect the standard, works only
-- with default link type URL and FILE. With custom directories you must
-- use the definition with a datalink as first parameter.
-- DLREPLACECONTENT(data-location-target , data-location-source, comment)
CREATE OR REPLACE FUNCTION dlreplacecontent(uri, uri, text) RETURNS datalink AS $$
        SELECT dlreplacecontent(NULL, $1, $2, $3);
$$ LANGUAGE SQL STRICT;

CREATE OR REPLACE FUNCTION dlreplacecontent(uri, uri) RETURNS datalink AS $$
        SELECT dlreplacecontent(NULL, $1, $2, NULL::text);
$$ LANGUAGE SQL STRICT;

-- When a datalink URI is set to zero length string or the datalink is set to NULL
-- or the row is simply delete we must remove the link 
CREATE OR REPLACE FUNCTION dlunlink() RETURNS trigger AS $$
DECLARE
    v_directory record;
    v_path text;
    v_dstpath text;
    v_ret boolean;
BEGIN
    -- First be sure the the datalink values is not already unlinked if we come from an UPDATE statement
    IF TG_OP = 'UPDATE' THEN
        IF OLD.efile IS NULL OR (OLD.efile).dl_path = '' THEN
            RETURN NEW;
        END IF;
    END IF;
    -- Get directory base informtion
    SELECT * INTO v_directory FROM dl_directory_base((OLD.efile).dl_base);
    IF NOT FOUND THEN
        -- If current Datalink is NULL then just delete or update the row
        IF OLD.efile IS NULL THEN
            IF TG_OP = 'UPDATE' THEN
                RETURN NEW;
            ELSE
                RETURN OLD;
            END IF;
        END IF;
        -- otherwise raise an nexception
        RAISE EXCEPTION 'The default base directory for the Datalink URL is not found.';
    END IF;
    -- If we do not have the link control just get out of here
    IF NOT v_directory.linkcontrol THEN
        IF TG_OP = 'UPDATE' THEN
            RETURN NEW;
        ELSE
            RETURN OLD;
        END IF;
    END IF;

    -- Check that we have write permission
    IF v_directory.writeperm THEN
        SELECT uri_get_path(dl_url_rebase((OLD.efile).dl_path, (OLD.efile).dl_base)) INTO v_path;
        IF NOT uri_path_exists(v_path::uri) THEN
            RAISE EXCEPTION 'Data location source file "%" must exists on filesystem.', v_path;
        END IF;
        -- Construct path to target file 
        IF (OLD.efile).dl_token IS NOT NULL THEN
            SELECT add_token_to_url(v_path, ((OLD.efile).dl_token)::text) INTO v_dstpath;
        END IF;
        IF v_directory.onunlink = 'RESTORE' THEN
            -- Then rename the file as the original one
            SELECT datalink_rename_localfile(v_dstpath, v_path) INTO v_ret;
            IF NOT v_ret THEN
                RAISE EXCEPTION 'can not rename file "%" into "%"', v_dstpath, v_path;
            END IF;
            -- FIXME: Now restore the old file attribut
        ELSE
            -- Just delete the link
            SELECT datalink_unlink_localfile(v_path::uri) INTO v_ret;
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

