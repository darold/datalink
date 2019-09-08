-------------------------------------------------------------------------------
-- Test datalink extension behavior with no link control
-------------------------------------------------------------------------------

\pset pager off

DROP DATABASE IF EXISTS test_datalink;
CREATE DATABASE test_datalink;

\c test_datalink

-- Create extension used to generate token
CREATE EXTENSION "uuid-ossp";

-- Create uri extension base type for datalink
CREATE EXTENSION uri;

-- Create datalink extension
CREATE EXTENSION datalink;

-- Create the table use to test the datalink extension
CREATE TABLE dl_example (
        ex_id bigint PRIMARY KEY,
        efile datalink
);

\echo --------------------------------------------------------------------------------
\echo Create a directory/prefix as URL base with no link control, this is the default
\echo --------------------------------------------------------------------------------
INSERT INTO pg_datalink_bases (dirname, base) VALUES ('public.dl_example.efile', 'file:///tmp/test_datalink/');
\x
SELECT * FROM pg_datalink_bases WHERE dirid > 0;
\x

\echo --------------------------------------------------------------------------------
\echo Register file /tmp/test_datalink/img1.png
\echo --------------------------------------------------------------------------------
INSERT INTO dl_example VALUES (1, dlvalue('img1.png'::uri, 'public.dl_example.efile'::text, 'Url must be rebased on test_dir directory'::text));
SELECT * FROM dl_example;
\echo --------------------------------------------------------------------------------
\echo Nothing must change on file system
\echo --------------------------------------------------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Try to read the content of file /etc/passwd with dlreadfile()
\echo Must raise an error reading URL is not authorized.
\echo --------------------------------------------------------------------------------
SELECT dlreadfile(A.efile, '/etc/passwd'::uri) FROM dl_example A WHERE A.ex_id = 1;

\echo --------------------------------------------------------------------------------
\echo Obtain a url without token (no link control) to read a file
\echo --------------------------------------------------------------------------------
SELECT dlurlcomplete(efile) FROM dl_example WHERE ex_id = 1;

\echo --------------------------------------------------------------------------------
\echo Obtain a token to write to the file: ERROR:  Can not write with NO LINK CONTROL.
\echo --------------------------------------------------------------------------------
SELECT dlurlcompletewrite(efile) FROM dl_example WHERE ex_id = 1;

\echo --------------------------------------------------------------------------------
\echo Try to register a file that is not on base directory 'public.dl_example.efile'
\echo Must raise an error: DataLink URL does not match directory base
\echo --------------------------------------------------------------------------------
INSERT INTO dl_example VALUES (2, dlvalue('/tmp/img2.png'::uri, 'public.dl_example.efile'::text, 'Error about wrong directory base'::text));

\echo --------------------------------------------------------------------------------
\echo Replace img1.png file with an other using dlvalue() in an update.
\echo This only affect the SQL part, not link control is set
\echo --------------------------------------------------------------------------------
UPDATE dl_example SET efile=dlvalue(efile, 'file5.txt'::uri, 'public.dl_example.efile'::text, 'Replace with dlvalue() the datalink but do not touch file on disk.'::text) WHERE ex_id=1;
SELECT * FROM dl_example;
\echo --------------------------------------------------------------------------------
\echo Nothing mightange in the directory and no token must have been generated
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Try to use dlnewcopy() which must result in error "writing is not authorized"
\echo --------------------------------------------------------------------------------
UPDATE dl_example SET efile=dlnewcopy(efile, 'img1.png'::uri, 'f') WHERE ex_id=1;

\echo --------------------------------------------------------------------------------
\echo Test the Datalink attributs chain
\echo --------------------------------------------------------------------------------
\echo Enable FILE LINK CONTROL, must complain that ON UNLINK shall be specified.
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET linkcontrol='t' WHERE dirid = 1;
\echo --------------------------------------------------------------------------------
\echo Set ON UNLINK to RESTORE, must complain that INTEGRITY ALL must be used
\echo if WRITE PERMISSION BLOCKED is specified
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET linkcontrol='t',onunlink='RESTORE' WHERE dirid = 1;
\echo --------------------------------------------------------------------------------
\echo Enable read / write perm at DB side: must complain that INTEGRITY SELECTIVE
\echo is not compatible with our config
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET linkcontrol='t',onunlink='RESTORE',readperm='t',writeperm='t' WHERE dirid = 1;
\echo --------------------------------------------------------------------------------
\echo Then set INTEGRITY ALL and update will be successful
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET linkcontrol='t',onunlink='RESTORE',readperm='t',writeperm='t',integrity='t' WHERE dirid = 1;

\echo --------------------------------------------------------------------------------
\echo Set writetoken to false to use basic .new and .old suffix to manipulate files.
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET writetoken='f' WHERE dirid = 1;
\echo --------------------------------------------------------------------------------
\echo Register a text file in 'public.dl_example.efile' base directory
\echo --------------------------------------------------------------------------------
INSERT INTO dl_example VALUES (3, dlvalue('file3.txt'::uri, 'public.dl_example.efile'::text, 'Text file to read'::text));
\echo --------------------------------------------------------------------------------
\echo Obtain the url of the file with no token part and
\echo verify that no token is generated in pg_dltoken
\echo --------------------------------------------------------------------------------
SELECT dlurlcompleteonly(efile) FROM dl_example WHERE ex_id = 3;
\echo --------------------------------------------------------------------------------
\echo Nothing might change in the directory and no token must have been generated
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Try to read the content of the file with a fake token,
\echo must raise an error can not stat file ... No such file or directory
\echo --------------------------------------------------------------------------------
SELECT dlreadfile(A.efile, '/etc/9331cdc3-b33e-48d9-aaf0-6994532d6647;passwd'::uri) FROM dl_example A WHERE A.ex_id = 1;

\echo --------------------------------------------------------------------------------
\echo Obtain a token to write the file. As writetoken is false this is the url only
\echo with .new suffix, then use dlnewcopy() to relink to new file and then call
\echo dlpreviouscopy() to restore the .old file. We show the content of the directory
\echo between each step.
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret text;
BEGIN
    -- Ask for a token, writetoken is false => url with .new suffix
    SELECT dlurlcompletewrite(efile) INTO v_uri FROM dl_example WHERE ex_id = 3;
    RAISE NOTICE 'Uri must have the .new prefix: %', v_uri;
    -- There should be file3.txt.new + file3.txt
    RAISE NOTICE 'Directory content after dlurlcompletewrite() of /tmp/test_datalink/ (must show file3.txt.new + file3.txt):';
    FOR v_ret IN SELECT * FROM pg_ls_dir('/tmp/test_datalink/') LOOP
        RAISE NOTICE '%', v_ret;
    END LOOP;
    -- Override linked file with new one
    UPDATE dl_example SET efile=dlnewcopy(efile, v_uri, 'f') WHERE ex_id=3;
    -- There should be file3.txt.old + file3.txt
    RAISE NOTICE 'Directory content after dlnewcopy() of /tmp/test_datalink/ (must show file3.txt.old + file3.txt):';
    FOR v_ret IN SELECT * FROM pg_ls_dir('/tmp/test_datalink') LOOP
        RAISE NOTICE '%', v_ret;
    END LOOP;
    -- Restore previous file 
    RAISE NOTICE 'Restore previous version of the file, rename .old file into file3.txt. The new copy is overridden.';
    UPDATE dl_example SET efile=dlpreviouscopy(efile, ((efile).dl_path::text||'.old')::uri, 'f') WHERE ex_id=3;
END;
$$;

\echo --------------------------------------------------------------------------------
\echo Initial state might be restored in the directory and no token generated
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Use replacecontent() with NO LINK CONTROL, must raise an error source file must
\echo exists on filesystem
\echo --------------------------------------------------------------------------------
UPDATE dl_example SET efile=dlreplacecontent(efile, 'file3.txt'::uri, 'file3.txt.new'::uri, 'Replace content'::text) WHERE ex_id=3;
\echo --------------------------------------------------------------------------------
\echo Create the new file file3.txt.new as a copy of file5.txt
\echo (cp /tmp/test_datalink/file5.txt /tmp/test_datalink/file3.txt.new)
\echo Call dlreplacecontent() again, no error must be raised and file content changed
\echo --------------------------------------------------------------------------------
\! sudo -u postgres cp /tmp/test_datalink/file5.txt /tmp/test_datalink/file3.txt.new
UPDATE dl_example SET efile=dlreplacecontent(efile, 'file3.txt'::uri, 'file3.txt.new'::uri, 'Replace content'::text) WHERE ex_id=3;
\echo --------------------------------------------------------------------------------
\echo There must be a file3.txt.old file and content of file must be from file5.txt
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------
\echo cat /tmp/test_datalink/file3.txt
\echo --------------------------------------------------------------------------------
\! cat /tmp/test_datalink/file3.txt
\echo --------------------------------------------------------------------------------
\echo Only the content have been replaced, the Datalink URI must stay the same
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example WHERE ex_id=3;
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Do the same test but with writetoken = true. Enable REQUIRE TOKEN FOR UPDATE
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET writetoken='t' WHERE dirid = 1;

\echo --------------------------------------------------------------------------------
\echo Obtain the url without token of the file and verify that no token is generated
\echo --------------------------------------------------------------------------------
SELECT dlurlcompleteonly(efile) FROM dl_example WHERE ex_id = 3;
\echo --------------------------------------------------------------------------------
\echo Initial state might be restored in the directory and no token generated
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------


\echo --------------------------------------------------------------------------------
\echo Obtain a token to write the file. As writetoken is true the file is copied with
\echo the token in his name. Then use dlnewcopy() to relink to new file and then call
\echo dlpreviouscopy() to restore the .old file. We show the content of the directory
\echo between each step.
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret text;
BEGIN
    -- Ask for a token, writetoken is false => url with .new suffix
    SELECT dlurlcompletewrite(efile) INTO v_uri FROM dl_example WHERE ex_id = 3;
    RAISE NOTICE 'Uri must have the token: %', v_uri;
    -- There should be file3.txt.new + file3.txt
    RAISE NOTICE 'Directory content for /tmp/test_datalink/ (must show XXXXXXXX;file3.txt, file3.txt.old from previous test and original file file3.txt):';
    FOR v_ret IN SELECT * FROM pg_ls_dir('/tmp/test_datalink/') LOOP
        RAISE NOTICE '%', v_ret;
    END LOOP;
    -- Override linked file with new one. As source file is a fresh one, rename it at .ol and create a link to this file so that the call to dlpreviouscopy will work
    -- Third parameter must be 't' to signal that we use token
    UPDATE dl_example SET efile=dlnewcopy(efile, v_uri, 't') WHERE ex_id=3;
    FOR v_ret IN SELECT (efile).dl_token FROM dl_example WHERE ex_id=3 LOOP
        RAISE NOTICE 'New token for record ex_id = 3: %; must be the same as the URL and cpied file', v_ret;
    END LOOP;
    -- There should be XXXXXXXX;file3.txt an file3.txt must be a symlink pointing to it
    RAISE NOTICE 'Directory content for /tmp/test_datalink/ must me the same as above as we just set the token in the SQL record:';
    FOR v_ret IN SELECT * FROM pg_ls_dir('/tmp/test_datalink') LOOP
        RAISE NOTICE '%', v_ret;
    END LOOP;
    -- Restore previous file from .old version
    -- Third parameter must be 't' to signal that we use token
    RAISE NOTICE 'Restore previous version of the file: dl_token is NULL and move the token as dl_prevtoken.';
    UPDATE dl_example SET efile=dlpreviouscopy(efile, v_uri, 't') WHERE ex_id=3;
END;
$$;
\echo --------------------------------------------------------------------------------
\echo The record must have the new token. The dl_token is NULL value because at
\echo origin the file was create with dlvalue() and no link control, so the previous
\echo file restored is file3.txt
\echo -----------------------------------------
SELECT * FROM dl_example WHERE ex_id = 3;
\echo --------------------------------------------------------------------------------
\echo Get a new token for reading to be sure that we are linking file3.txt
\echo --------------------------------------------------------------------------------
SELECT dlurlcomplete(efile) FROM dl_example WHERE ex_id = 3;

\echo --------------------------------------------------------------------------------
\echo There must be token created xx-xxxX-xx;file3.txt and file3.txt be regular files
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo Set attribute RECOVERY YES to enable archiving all Datalink created/modified
\echo will be registered into table pg_datalink_archives.
UPDATE pg_datalink_bases SET recovery='t' WHERE dirid = 1;

\echo --------------------------------------------------------------------------------
\echo Test insert with dlvalues() and an existing new file with a token. The token of
\echo the file must be inserted into the dl_token part of the Datalink and the file
\echo name kept unchanged.
\echo --------------------------------------------------------------------------------
\! sudo -u postgres mv '/tmp/32391569-3aed-419f-9921-7399ecc9d980;file6.txt' /tmp/test_datalink/
INSERT INTO dl_example VALUES (4, dlvalue('32391569-3aed-419f-9921-7399ecc9d980;file6.txt'::uri, 'public.dl_example.efile'::text, 'Link file already including a token'::text));
SELECT * FROM dl_example WHERE ex_id=4;

\echo --------------------------------------------------------------------------------
\echo Test read and write to file using datalink functions and token
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret boolean;
    v_content bytea;
BEGIN
    -- Ask for a read token
    SELECT dlurlcomplete(efile) INTO v_uri FROM dl_example WHERE ex_id = 3;
    RAISE NOTICE 'Uri with token to read: %', v_uri;
    -- Read content of the file
    SELECT dlreadfile(A.efile, v_uri) INTO v_content FROM dl_example A WHERE A.ex_id = 3;
    RAISE NOTICE 'File content: %', convert_from(v_content, 'utf8');
    -- Write to the file
    SELECT dlurlcompletewrite(efile) INTO v_uri FROM dl_example WHERE ex_id = 4;
    RAISE NOTICE 'Uri with token to write: %', v_uri;
    SELECT dlwritefile(A.efile, v_uri, v_content) INTO v_ret FROM dl_example A WHERE A.ex_id = 4;
    RAISE NOTICE 'Content written: %', v_ret;
    UPDATE dl_example SET efile=dlnewcopy(efile, v_uri, 't') WHERE ex_id=4;
END;
$$;
\echo --------------------------------------------------------------------------------
\echo Record with ex_id = 4 must have the token of the new written file,
\echo and the previous token filled by the token of its creation time
\echo -----------------------------------------
SELECT * FROM dl_example WHERE ex_id=4;

\echo --------------------------------------------------------------------------------
\echo There must be token created xx-xxxX-xx;file3.txt and file3.txt be regular files
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Try to read Uri without token, must raise an error can not found a token in url
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret boolean;
    v_content bytea;
BEGIN
    -- Ask for a read token
    SELECT dlurlcompleteonly(efile) INTO v_uri FROM dl_example WHERE ex_id = 4;
    -- Read content of the file
    SELECT dlreadfile(A.efile, v_uri) INTO v_content FROM dl_example A WHERE A.ex_id = 4;
END;
$$;

\echo --------------------------------------------------------------------------------
\echo Test to read a file with a fake token, must raise an error can not stat file
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret boolean;
    v_content bytea;
BEGIN
    -- Ask for a read token
    SELECT dlurlcomplete(efile) INTO v_uri FROM dl_example WHERE ex_id = 4;
    -- Read content of the file
    SELECT dlreadfile(A.efile, '/etc/212699ba-a0a9-4bd9-8e0a-99e9ba957df8;passwd'::uri) INTO v_content FROM dl_example A WHERE A.ex_id = 4;
END;
$$;


\echo --------------------------------------------------------------------------------
\echo Test dlreplacecontent with a token, should warn that the file does not exist
\echo (invalid token), a copy is normally done using dlurlcompletewrite() but not with
\echo dlurlcomplete() like here
\echo --------------------------------------------------------------------------------
DO $$
DECLARE
    v_uri uri;
    v_ret boolean;
    v_content bytea;
BEGIN
    -- Ask for a read token
    SELECT dlurlcomplete(efile) INTO v_uri FROM dl_example WHERE ex_id = 3;
    UPDATE dl_example SET efile=dlreplacecontent(efile, 'file3.txt'::uri, v_uri, 'Replace content'::text) WHERE ex_id=3;
END;
$$;

\echo --------------------------------------------------------------------------------
\echo Show content of external file directory
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Replace content of file3.txt using the right functions and tokens
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example WHERE ex_id=4;
BEGIN WORK;
DO $$
DECLARE
    v_uri uri;
    v_ret boolean;
    v_content bytea;
BEGIN
    -- Ask for a read token
    SELECT dlurlcompletewrite(efile) INTO v_uri FROM dl_example WHERE ex_id = 4;
    RAISE NOTICE 'Uri with token to write: %', v_uri;
    SELECT dlwritefile(A.efile, v_uri, 'Hello world'::bytea) INTO v_ret FROM dl_example A WHERE A.ex_id = 4;
    RAISE NOTICE 'Write to "%s" done.', v_uri;
    UPDATE dl_example SET efile=dlreplacecontent(efile, 'file6.txt'::uri, v_uri, 'Replace content'::text) WHERE ex_id=4;
    RAISE NOTICE 'Content of file "%" should be: "Hello world"', v_uri;
END;
$$;
END WORK;

\echo --------------------------------------------------------------------------------
\echo Show content of external file directory
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo the current and old token must reflect the two regular file on disk
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example WHERE ex_id=4;

\echo --------------------------------------------------------------------------------
\echo Look at file to archives, should return one record for file6.txt
\echo --------------------------------------------------------------------------------
SELECT * FROM pg_datalink_archives;

