------------------------------------------------------------------------------
-- Basic datalink tests 
------------------------------------------------------------------------------
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

----------------------------------------------------------------------------

\pset null <NULL>

\echo --------------------------------------------------------------------------------
\echo Create a test Datalink base ('public.dl_example.efile') with DB full control
\echo --------------------------------------------------------------------------------
INSERT INTO public.pg_datalink_bases VALUES (1, 'public.dl_example.efile', 'file:///tmp/test_datalink/', true, true, true, true, true, true, false, 'RESTORE');

\echo --------------------------------------------------------------------------------
\echo Test DLVALUE function
\echo --------------------------------------------------------------------------------
-- NULL as DLVALUE
INSERT INTO dl_example VALUES (97, NULL);
-- The DATALINK value only includes an uri (cast it as uri
-- otherwise as text data type it will be taken as comment)
INSERT INTO dl_example VALUES (98,DLVALUE('http://pgbadger.darold.net/'::uri));
-- If the DATALINK value only includes the comment the uri must
-- be a zero length string and the directory can be NULL.
INSERT INTO dl_example VALUES (99,DLVALUE('Just a comment'::text));
-- DLVALUE can be used in UPDATE statement to just override previous, here with a NULL record
UPDATE dl_example SET efile=DLVALUE(efile, 'Comment only'::text)::datalink WHERE ex_id=97;
DELETE FROM dl_example WHERE ex_id=97;
INSERT INTO dl_example VALUES (100, DLVALUE('http://pgcluu.darold.net/index.html'::uri,'URL','Main page of pgCluu site'));
INSERT INTO public.dl_example VALUES (1, DLVALUE('img1.png'::uri,'public.dl_example.efile', 'Image in the test datalink directory'));
\echo --------------------------------------------------------------------------------
\echo Look for Datalink example, only last entry (ex_id=1) must have a token,
\echo other entries use default base directory with no link control
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example;

\echo --------------------------------------------------------------------------------
\echo Test DLCOMMENT function
\echo --------------------------------------------------------------------------------
SELECT DLCOMMENT(efile) FROM dl_example WHERE ex_id=100;
SELECT DLCOMMENT(NULL);

\echo --------------------------------------------------------------------------------
\echo Test DLLINKTYPE function
\echo --------------------------------------------------------------------------------
SELECT DLLINKTYPE(efile) FROM dl_example WHERE ex_id=100;
INSERT INTO dl_example VALUES (101, DLVALUE('/var/lib/pgsql/11/data/testfile.txt'::uri,NULL,'Test default link type FILE.'));
SELECT DLLINKTYPE(efile) FROM dl_example WHERE ex_id=101;
INSERT INTO dl_example VALUES (102, DLVALUE('http://www.darold.net/index.html'::uri,NULL,'Test default link type URL.'));
SELECT DLLINKTYPE(efile) FROM dl_example WHERE ex_id=102;
\echo --------------------------------------------------------------------------------
\echo Must return the base directory insted of default link type FILE or URL
\echo --------------------------------------------------------------------------------
SELECT DLLINKTYPE(efile) FROM dl_example WHERE ex_id=1;
\echo --------------------------------------------------------------------------------
\echo Change behavior of default directories just for some test:
\echo linkcontrol='t',integrity='t',readperm='t',writeperm='t',onunlink='DELETE'
\echo --------------------------------------------------------------------------------
UPDATE pg_datalink_bases SET linkcontrol='t',integrity='t',readperm='t',writeperm='t',onunlink='DELETE' WHERE dirid <= 0;
INSERT INTO pg_datalink_bases VALUES (100, 'test_directory', 'http://www.darold.net/', 'f');
INSERT INTO dl_example VALUES (103, DLVALUE('http://www.darold.net/index.html'::uri,'test_directory','Test directory link type.'));
SELECT DLLINKTYPE(efile) FROM dl_example WHERE ex_id=103;
SELECT DLLINKTYPE(NULL);

\echo --------------------------------------------------------------------------------
\echo Test DLURLSCHEME function
\echo --------------------------------------------------------------------------------
SELECT DLURLSCHEME(efile) FROM dl_example WHERE ex_id=100;
SELECT DLURLSCHEME(efile) FROM dl_example WHERE ex_id=101;
INSERT INTO pg_datalink_bases VALUES (101, 'ldap_directory', 'ldap://', 'f');
INSERT INTO dl_example VALUES (104, DLVALUE('ldap://www.darold.net/'::uri,'ldap_directory',NULL));
SELECT DLURLSCHEME(efile) FROM dl_example WHERE ex_id=104;
SELECT DLURLSCHEME(NULL);
\echo --------------------------------------------------------------------------------
\echo When DATALINK value only includes comment the result is a zero length string.
\echo --------------------------------------------------------------------------------
SELECT DLURLSCHEME(efile) FROM dl_example WHERE ex_id=99;

\echo --------------------------------------------------------------------------------
\echo Test DLURLSERVER function
\echo --------------------------------------------------------------------------------
\echo --------------------------------------------------------------------------------
\echo Must raise a warning about function that to be use with URL only
\echo --------------------------------------------------------------------------------
SELECT DLURLSERVER(efile) FROM dl_example WHERE ex_id=101;
SELECT DLURLSERVER(efile) FROM dl_example WHERE ex_id=104;
SELECT DLURLSERVER(NULL);
\echo --------------------------------------------------------------------------------
\echo When DATALINK value only includes comment the result is a zero length string.
\echo --------------------------------------------------------------------------------
SELECT DLURLSERVER(efile) FROM dl_example WHERE ex_id=99;

\echo --------------------------------------------------------------------------------
\echo Test DLURLCOMPLETE function
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETE(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLCOMPLETE(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLCOMPLETE(NULL);
\echo --------------------------------------------------------------------------------
\echo Must raise an error can not link remote URI
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETE(efile) FROM dl_example WHERE ex_id=102;

\echo --------------------------------------------------------------------------------
\echo At this stage img1.png have been renamed with a token by call to dlvalue() at
\echo insert and no token must have been generated in /tmp/test_datalink/pg_dltoken/
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Must create a token for reading 
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETE(efile) FROM dl_example WHERE ex_id=1;
\echo --------------------------------------------------------------------------------
\echo A link with token pointing to img1.png (with token) file must exist and the
\echo dl_token directory must contain the token for reading used in the symlink name
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory: (W=0000000 3057 R=0000000 3052)
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\! find /tmp/test_datalink/pg_dltoken/ -name '*' -type f | xargs -i hexdump {} | grep "^0000000 305[27]" | wc -l
\echo
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Test DLURLCOMPLETEONLY function
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETEONLY(efile) FROM dl_example WHERE ex_id=102;
SELECT DLURLCOMPLETEONLY(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLCOMPLETEONLY(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLCOMPLETEONLY(efile) FROM dl_example WHERE ex_id=1;
SELECT DLURLCOMPLETEONLY(NULL);

\echo --------------------------------------------------------------------------------
\echo Test DLURLPATH function
\echo --------------------------------------------------------------------------------
SELECT DLURLPATH(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLPATH(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLPATH(NULL);
\echo --------------------------------------------------------------------------------
\echo Must raise a notice can not link remote URI
\echo --------------------------------------------------------------------------------
SELECT DLURLPATH(efile) FROM dl_example WHERE ex_id=102;
\echo --------------------------------------------------------------------------------
\echo Must create a token for reading 
\echo --------------------------------------------------------------------------------
SELECT DLURLPATH(efile) FROM dl_example WHERE ex_id=1;
\echo --------------------------------------------------------------------------------
\echo An other link with token pointing to img1.png (with token) file must exist and the
\echo dl_token directory must contain the new token for reading used in the symlink name
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory: (W=0000000 3057 R=0000000 3052)
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\! find /tmp/test_datalink/pg_dltoken/ -name '*' -type f | xargs -i hexdump {} | grep "^0000000 305[27]" | wc -l
\echo
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Test DLURLPATHONLY function
\echo --------------------------------------------------------------------------------
SELECT DLURLPATHONLY(efile) FROM dl_example WHERE ex_id=102;
SELECT DLURLPATHONLY(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLPATHONLY(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLPATHONLY(efile) FROM dl_example WHERE ex_id=1;
SELECT DLURLPATHONLY(NULL);

\echo --------------------------------------------------------------------------------
\echo Test DLURLCOMPLETEWRITE function
\echo --------------------------------------------------------------------------------
\echo --------------------------------------------------------------------------------
\echo Must raise an error that it can not write to a remote URL
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETEWRITE(efile) FROM dl_example WHERE ex_id=102;
\echo --------------------------------------------------------------------------------
\echo Must raise an error about no link control
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETEWRITE(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLCOMPLETEWRITE(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLCOMPLETEWRITE(NULL);
\echo --------------------------------------------------------------------------------
\echo Test DLURLPATHWRITE function
\echo --------------------------------------------------------------------------------
\echo --------------------------------------------------------------------------------
\echo Must raise an error that it can not write to a remote URL
\echo --------------------------------------------------------------------------------
SELECT DLURLPATHWRITE(efile) FROM dl_example WHERE ex_id=102;
\echo --------------------------------------------------------------------------------
\echo Must raise an error about no link control
\echo --------------------------------------------------------------------------------
SELECT DLURLPATHWRITE(efile) FROM dl_example WHERE ex_id=103;
SELECT DLURLPATHWRITE(efile) FROM dl_example WHERE ex_id=99;
SELECT DLURLPATHWRITE(NULL);
\echo --------------------------------------------------------------------------------
\echo Content of /tmp/test_datalink/ and /tmp/test_datalink/pg_dltoken/ must be unchanged
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory:
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Test DLURLCOMPLETEWRITE and DLURLPATHWRITE functions with token
\echo --------------------------------------------------------------------------------
\echo --------------------------------------------------------------------------------
\echo Must create a token for writing 
\echo --------------------------------------------------------------------------------
SELECT DLURLCOMPLETEWRITE(efile) FROM dl_example WHERE ex_id=1;
\echo --------------------------------------------------------------------------------
\echo A copy of file img1.png with a token for writing must exist
\echo dl_token directory must contain the token for writing used in the file name
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory: (W=0000000 3057 R=0000000 3052)
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\! find /tmp/test_datalink/pg_dltoken/ -name '*' -type f | xargs -i hexdump {} | grep "^0000000 305[27]" | wc -l
\echo
\echo --------------------------------------------------------------------------------
SELECT DLURLPATHWRITE(efile) FROM dl_example WHERE ex_id=1;
\echo --------------------------------------------------------------------------------
\echo A new copy of file img1.png with a token for writing must exist
\echo dl_token directory must contain the token for writing used in the file name
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory: (W=0000000 3057 R=0000000 3052)
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\! find /tmp/test_datalink/pg_dltoken/ -name '*' -type f | xargs -i hexdump {} | grep "^0000000 305[27]" | wc -l
\echo
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Final content of the DL_EXAMPLE table
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example;

\echo --------------------------------------------------------------------------------
\echo Rollback a transaction that open a datalink for writing
\echo --------------------------------------------------------------------------------
BEGIN;
SELECT DLURLPATHWRITE(efile) FROM dl_example WHERE ex_id=1;
ROLLBACK;
\echo --------------------------------------------------------------------------------
\echo A new copy of file img1.png with a token for writing must exist
\echo dl_token directory must contain the token for writing used in the file name
\echo Both files (token and copy) must be removed by the bgworker cleaner.
\echo Content of /tmp/test_datalink/ directory:
\echo -----------------------------------------
\! ls -l /tmp/test_datalink/ | grep -v total
\echo Content of /tmp/test_datalink/pg_dltoken/ directory: (W=0000000 3057 R=0000000 3052)
\echo ----------------------------------------------------
\! ls -l /tmp/test_datalink/pg_dltoken | grep -v total
\! find /tmp/test_datalink/pg_dltoken/ -name '*' -type f | xargs -i hexdump {} | grep "^0000000 305[27]" | wc -l
\echo
\echo --------------------------------------------------------------------------------

\echo --------------------------------------------------------------------------------
\echo Content of the DL_EXAMPLE table must have not changed
\echo --------------------------------------------------------------------------------
SELECT * FROM dl_example;

