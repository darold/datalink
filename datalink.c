/* *
 * Datalink is an extention to bring SQL/MED datalink support
 * Author: Gilles Darold (gilles@darold.net)
 * Copyright (c) 2015-2019 Gilles Darold - All rights reserved.
 * */

#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "string.h"
#include "catalog/pg_type.h"
#include "utils/builtins.h"
#include "storage/fd.h"
#include "utils/memutils.h"
#include "storage/lwlock.h"
#include "access/xact.h"
#include "access/transam.h"
#include "utils/snapmgr.h"
#include "utils/varlena.h"
#include "utils/guc.h"

#include "datalink.h"

static bytea * read_binary_file(const char *filename, int64 seek_offset,
		int64 bytes_to_read, bool missing_ok);
 
PG_MODULE_MAGIC;

/*
 * Declaration of the DATALINK data type function
 */
Datum		datalink_copy_localfile(PG_FUNCTION_ARGS);
Datum		datalink_unlink_localfile(PG_FUNCTION_ARGS);
Datum		datalink_read_localfile(PG_FUNCTION_ARGS);
Datum		datalink_write_localfile(PG_FUNCTION_ARGS);
Datum		datalink_rename_localfile(PG_FUNCTION_ARGS);
Datum		datalink_createlink_localfile(PG_FUNCTION_ARGS);
Datum		datalink_relink_localfile(PG_FUNCTION_ARGS);
Datum		datalink_register_token(PG_FUNCTION_ARGS);
Datum		datalink_verify_token(PG_FUNCTION_ARGS);
Datum		datalink_is_symlink(PG_FUNCTION_ARGS);
Datum		datalink_symlink_target(PG_FUNCTION_ARGS);


PG_FUNCTION_INFO_V1(datalink_copy_localfile);
Datum
datalink_copy_localfile(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	text    *dst = PG_GETARG_TEXT_PP(1);
	int     fd_in, fd_out;
	int     inbytes, outbytes;
	long    total_bytes;
	char    buf[BUFFER_SIZE];
	char    in_fnamebuf[MAXPGPATH];
	char    out_fnamebuf[MAXPGPATH];
	mode_t  oumask;
	struct flock flin;
	struct flock flout;

	text_to_cstring_buffer(src, in_fnamebuf, sizeof(in_fnamebuf));
	fd_in = OpenTransientFile(in_fnamebuf, O_RDONLY | PG_BINARY);
	if (fd_in < 0) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open server file \"%s\": %m",
						in_fnamebuf)));
	}

	/* Lock file for share or return false if it can't e acquired */
	flin.l_type = F_RDLCK;
	flin.l_whence = SEEK_SET;
	flin.l_start = 0;
	flin.l_len = 0;
	if (fcntl(fd_in, F_SETLK, &flin) == -1)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("can not lock file for reading \"%s\": %m",
						in_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

	/* Open the new output file */
	text_to_cstring_buffer(dst, out_fnamebuf, sizeof(out_fnamebuf));
	oumask = umask(S_IWGRP | S_IWOTH);
	fd_out = OpenTransientFilePerm(out_fnamebuf, O_CREAT | O_WRONLY | O_TRUNC | PG_BINARY,
						S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
	umask(oumask);
	if (fd_out < 0) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create server file \"%s\": %m",
						out_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

	/* Lock file for exclusive or return false if it can't be acquired */
	flout.l_type = F_WRLCK;
	flout.l_whence = SEEK_SET;
	flout.l_start = 0;
	flout.l_len = 0;
	if (fcntl(fd_out, F_SETLK, &flout) == -1)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("can not lock file for writing \"%s\": %m",
						out_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

        while ((inbytes = read(fd_in, buf, BUFFER_SIZE)) > 0)
        {
                outbytes = write(fd_out, buf, inbytes);
		if (outbytes < 0) {
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not write server file \"%s\": %m",
							out_fnamebuf)));
			PG_RETURN_BOOL(false);
		}

		total_bytes += inbytes;
        }

	/* Close the files and release the locks */
	if (CloseTransientFile(fd_in))
		 ereport(ERROR,
				 (errcode_for_file_access(),
				  errmsg("could not close file \"%s\": %m", in_fnamebuf)));
	if (CloseTransientFile(fd_out))
		 ereport(ERROR,
				 (errcode_for_file_access(),
				  errmsg("could not close file \"%s\": %m", out_fnamebuf)));

	/* Check that we have read something */
        if (inbytes < 0) {
                ereport(ERROR,
                                (errcode_for_file_access(),
                                 errmsg("could not read server file \"%s\": %m",
                                                in_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

	PG_RETURN_BOOL(true);
}

PG_FUNCTION_INFO_V1(datalink_unlink_localfile);
Datum
datalink_unlink_localfile(PG_FUNCTION_ARGS)
{
	text    *filename = PG_GETARG_TEXT_PP(0);
	char    in_fnamebuf[MAXPGPATH];

	text_to_cstring_buffer(filename, in_fnamebuf, sizeof(in_fnamebuf));
        if (unlink(in_fnamebuf) < 0)
        {
                ereport(WARNING,
                                (errcode_for_file_access(),
                                 errmsg("could not unlink file \"%s\": %m", in_fnamebuf)));

                PG_RETURN_BOOL(false);
        }

        PG_RETURN_BOOL(true);
}

PG_FUNCTION_INFO_V1(datalink_read_localfile);
Datum
datalink_read_localfile(PG_FUNCTION_ARGS)
{
	text       *filename = PG_GETARG_TEXT_PP(0);
	int64      seek_offset = PG_GETARG_INT64(1);
	int64      bytes_to_read = PG_GETARG_INT64(2);
	char       in_fnamebuf[MAXPGPATH];
	bool       missing_ok = false;
	bytea      *result;

	text_to_cstring_buffer(filename, in_fnamebuf, sizeof(in_fnamebuf));

	if (bytes_to_read < 0)
	{
		/* Read full file content, get file size */
		struct stat    statbuf;
		char          *dstpath;

		dstpath = realpath(in_fnamebuf, NULL);
		if (dstpath == NULL)
		{
			if (errno != ENOENT)
				ereport(ERROR, (
					errmsg("could not get real path of file \"%s\": %s",
							in_fnamebuf, strerror(errno))));
			PG_RETURN_NULL();
		}
		if (stat(dstpath, &statbuf) < 0)
		{
			free(dstpath);
			if (errno != ENOENT)
				ereport(ERROR, (
					errmsg("could not stat file \"%s\": %s",
							in_fnamebuf, strerror(errno))));
			PG_RETURN_NULL();
		}

		bytes_to_read = statbuf.st_size;
		free(dstpath);
	}

	result = read_binary_file(in_fnamebuf, seek_offset,
						bytes_to_read, missing_ok);
	if (result)
		PG_RETURN_BYTEA_P(result);
	else
		PG_RETURN_NULL();
}

PG_FUNCTION_INFO_V1(datalink_write_localfile);
Datum
datalink_write_localfile(PG_FUNCTION_ARGS)
{
	text       *filename = PG_GETARG_TEXT_PP(0);
	bytea      *wbuf = PG_GETARG_BYTEA_PP(1);
        int        fd;
        char       in_fnamebuf[MAXPGPATH];
        mode_t     oumask;
        int64      totalwritten;
        struct flock fl;


	text_to_cstring_buffer(filename, in_fnamebuf, sizeof(in_fnamebuf));
	oumask = umask(S_IWGRP | S_IWOTH);
	fd = OpenTransientFile(in_fnamebuf, O_CREAT | O_WRONLY | O_TRUNC | PG_BINARY);
	umask(oumask);
	if (fd < 0) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create server file \"%s\": %m",
						in_fnamebuf)));
                PG_RETURN_BOOL(false);
        }
	/* Exclusive lock file for writing or return false if it can't e acquired */
	fl.l_type = F_WRLCK;
	fl.l_whence = SEEK_SET;
	fl.l_start = 0;
	fl.l_len = 0;
	if (fcntl(fd, F_SETLK, &fl) == -1)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("can not lock file for reading \"%s\": %m",
						in_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

	/*
	 * write to the filesystem
	 */
	totalwritten = write(fd, VARDATA_ANY(wbuf), VARSIZE_ANY_EXHDR(wbuf));
	if (totalwritten < 0) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write server file \"%s\": %m",
						in_fnamebuf)));
                PG_RETURN_BOOL(false);
	} else if (totalwritten != VARSIZE_ANY_EXHDR(wbuf)) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("error when writting to server file \"%s\": %m",
						in_fnamebuf)));
                PG_RETURN_BOOL(false);
        }
	if (pg_fsync(fd) != 0)
		ereport(data_sync_elevel(ERROR),
				(errcode_for_file_access(),
				 errmsg("could not fsync file \"%s\": %m", in_fnamebuf)));

	if (CloseTransientFile(fd))
		 ereport(ERROR,
				 (errcode_for_file_access(),
				  errmsg("could not close file \"%s\": %m", in_fnamebuf)));

        PG_RETURN_BOOL(true);
}

PG_FUNCTION_INFO_V1(datalink_rename_localfile);
Datum
datalink_rename_localfile(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	text    *dst = PG_GETARG_TEXT_PP(1);
	char    in_fnamebuf[MAXPGPATH];
	char    out_fnamebuf[MAXPGPATH];

	text_to_cstring_buffer(src, in_fnamebuf, sizeof(in_fnamebuf));
	text_to_cstring_buffer(dst, out_fnamebuf, sizeof(out_fnamebuf));

	if (rename(in_fnamebuf, out_fnamebuf) < 0) {
		ereport(LOG,
				(errcode_for_file_access(),
				  errmsg("could not rename file \"%s\" to \"%s\": %m",
						in_fnamebuf, out_fnamebuf)));
		PG_RETURN_BOOL(false);
	}

	PG_RETURN_INT32(true);
}

/* Function used to link a file to a datalink newly inserted with DLVALUE */
PG_FUNCTION_INFO_V1(datalink_createlink_localfile);
Datum
datalink_createlink_localfile(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	text    *dst = PG_GETARG_TEXT_PP(1);
	char    in_fnamebuf[MAXPGPATH];
	char    out_fnamebuf[MAXPGPATH];

	text_to_cstring_buffer(src, in_fnamebuf, sizeof(in_fnamebuf));
	text_to_cstring_buffer(dst, out_fnamebuf, sizeof(out_fnamebuf));

	/* Create a symlink to the new file using origin filename */
	if (symlink(out_fnamebuf, in_fnamebuf) == -1)
		ereport(ERROR,
				(errcode_for_file_access(),
				  errmsg("could not symlink \"%s\" to renamed file \"%s\": %m",
						in_fnamebuf, out_fnamebuf)));

	PG_RETURN_INT32(true);
}

/* Function used to change link from a datalink to an other */
PG_FUNCTION_INFO_V1(datalink_relink_localfile);
Datum
datalink_relink_localfile(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	text    *dst = PG_GETARG_TEXT_PP(1);
	char    src_fnamebuf[MAXPGPATH];
	char    dst_fnamebuf[MAXPGPATH];

	text_to_cstring_buffer(src, src_fnamebuf, sizeof(src_fnamebuf));
	text_to_cstring_buffer(dst, dst_fnamebuf, sizeof(dst_fnamebuf));

	/*  Remove the symlink */
	if (unlink(src_fnamebuf) < 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				  errmsg("could not unlink symlink \"%s\": %m",
						src_fnamebuf)));

	/* Create a symlink to the new file using origin filename */
	if (symlink(dst_fnamebuf, src_fnamebuf) == -1)
		ereport(ERROR,
				(errcode_for_file_access(),
				  errmsg("could not symlink \"%s\" to renamed file \"%s\": %m",
						src_fnamebuf, dst_fnamebuf)));

	PG_RETURN_INT32(true);
}

/*
 * Read a section of a file, returning it as bytea
 * Caller is responsible for all permissions checking.
 * We read the whole of the file when bytes_to_read is negative.
 * Taken from src/backend/utils/adt/genfile.c and redefined here
 * to be used with non superuser roles.
 */
static bytea *
read_binary_file(const char *filename, int64 seek_offset, int64 bytes_to_read,
                                 bool missing_ok)
{
	bytea       *buf;
	size_t       nbytes;
	FILE        *file;
	int          fd;
        struct flock fl;

	if (bytes_to_read < 0)
	{
		if (seek_offset < 0)
			bytes_to_read = -seek_offset;
		else
		{
			struct stat fst;

			if (stat(filename, &fst) < 0)
			{
				if (missing_ok && errno == ENOENT)
					return NULL;
				else
					ereport(ERROR,
							(errcode_for_file_access(),
							 errmsg("could not stat file \"%s\": %m", filename)));
			}

			bytes_to_read = fst.st_size - seek_offset;
		}
	}

	/* not sure why anyone thought that int64 length was a good idea */
	if (bytes_to_read > (MaxAllocSize - VARHDRSZ))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("requested length too large")));

	if ((file = AllocateFile(filename, PG_BINARY_R)) == NULL)
	{
		if (missing_ok && errno == ENOENT)
			return NULL;
		else
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not open file \"%s\" for reading: %m",
							filename)));
	}
	fd = fileno(file);
	/* Lock file for share or return false if it can't e acquired */
	fl.l_type = F_RDLCK;
	fl.l_whence = SEEK_SET;
	fl.l_start = 0; /* we probably should only lock part of the file */
	fl.l_len = 0;   /* that is covered by seek_offset and bytes_to_read */
	if (fcntl(fd, F_SETLK, &fl) == -1)
	{
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("can not lock file for reading \"%s\": %m",
						filename)));
	}

	if (fseeko(file, (off_t) seek_offset,
			   (seek_offset >= 0) ? SEEK_SET : SEEK_END) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in file \"%s\": %m", filename)));

	buf = (bytea *) palloc((Size) bytes_to_read + VARHDRSZ);

	nbytes = fread(VARDATA(buf), 1, (size_t) bytes_to_read, file);

	if (ferror(file))
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not read file \"%s\": %m", filename)));

	SET_VARSIZE(buf, nbytes + VARHDRSZ);

	FreeFile(file);

	return buf;
}

PG_FUNCTION_INFO_V1(datalink_register_token);
Datum
datalink_register_token(PG_FUNCTION_ARGS)
{
	text    *token = PG_GETARG_TEXT_PP(0);
	text    *type = PG_GETARG_TEXT_PP(1);
	text    *path = PG_GETARG_TEXT_PP(2);
	char    *token_str = text_to_cstring(token);
	FILE    *fd_out;
	int     nwrite;
	char    out_fnamebuf[MAXPGPATH];
	mode_t  oumask;
	struct flock flout;
	TransactionId   topxid = GetTopTransactionId();
	char	   *dl_token_path;
	struct token_data itoken;

	/* Token access control can only be used in a transaction */
	if (topxid == InvalidTransactionId)
		ereport(ERROR,
				(errcode(ERRCODE_NO_ACTIVE_SQL_TRANSACTION),
				 errmsg("Datalink token access control can only be used in transactions")));

	/* Set binary struct for token information */
	strncpy(itoken.mode, text_to_cstring(type), sizeof(itoken.mode));
	itoken.txid = topxid; 
	strncpy(itoken.dlpath, text_to_cstring(path), sizeof(itoken.dlpath));

	/* Get value of the datalink.dl_token_path GUC */
	dl_token_path = GetConfigOptionByName("datalink.dl_token_path", NULL, false);

	/* Open the token file */
	snprintf(out_fnamebuf, sizeof(out_fnamebuf), "%s/%s", dl_token_path, token_str);
	oumask = umask(S_IWGRP | S_IWOTH);
	fd_out = fopen(out_fnamebuf, "w");
	umask(oumask);
	if (!fd_out) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create token server file \"%s\": %m",
						out_fnamebuf)));
	}

	/* Lock file for exclusive or return false if it can't be acquired */
	flout.l_type = F_WRLCK;
	flout.l_whence = SEEK_SET;
	flout.l_start = 0;
	flout.l_len = 0;
	if (fcntl(fileno(fd_out), F_SETLK, &flout) == -1)
	{
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("can not lock file for writing \"%s\": %m",
						out_fnamebuf)));
	}

	/* 
	 * Perhaps we shoud store the create timestamp to avoid
	 * issue with stat and system time that can change. For
	 * the moment just store the token type R (read) or W (write).
	 */
        nwrite = fwrite(&itoken, sizeof(struct token_data), 1, fd_out);

	/* Close the files and release the locks */
	if (fclose(fd_out) != 0)
		 ereport(ERROR,
				 (errcode_for_file_access(),
				  errmsg("could not close file \"%s\": %m", out_fnamebuf)));
	if (nwrite != 1) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write to file \"%s\": %m",
						out_fnamebuf)));
	}

	PG_RETURN_BOOL(true);
}

PG_FUNCTION_INFO_V1(datalink_verify_token);
Datum
datalink_verify_token(PG_FUNCTION_ARGS)
{
	text    *token = PG_GETARG_TEXT_PP(0);
	char    *token_str = text_to_cstring(token);
	bool    haswrite = PG_GETARG_BOOL(1);
	FILE    *fd_in;
	int     nread;
	char    in_fnamebuf[MAXPGPATH];
	bool    allowed = false;
	struct  flock flin;
	struct  stat fst;
	time_t  curtime;
	const char *status;
	char	   *dl_token_path;
	char	   *dl_token_expiry;
	struct token_data itoken;

	/* Get value of the datalink.dl_token_path GUC */
	dl_token_path = GetConfigOptionByName("datalink.dl_token_path", NULL, false);
	/* Get value of the datalink.dl_token_expire_after GUC */
	dl_token_expiry = GetConfigOptionByName("datalink.dl_token_expiry", NULL, false);

	/* Open the token file */
	snprintf(in_fnamebuf, sizeof(in_fnamebuf), "%s/%s", dl_token_path, token_str);

	/* First verify that the token has not expired */
	if (stat(in_fnamebuf, &fst) == -1)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("can not stat file \"%s\": %m", in_fnamebuf)));

	curtime = time(NULL);
	if (curtime - fst.st_ctime > atoi(dl_token_expiry))
	{
		/* remove the file it will not be used anymore */
		if (unlink(in_fnamebuf) != 0 && errno != ENOENT)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not remove token file \"%s\": %m", in_fnamebuf)));
		/* log a warning to warn that a token has expired */
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("token \"%s\" to file \"%s\" has expired, %ld seconds after its creation.",
						token_str, in_fnamebuf, curtime - fst.st_ctime)));
	}

	/* Look at file content */
	fd_in = fopen(in_fnamebuf, "r");
	if (!fd_in) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open server file \"%s\": %m",
						in_fnamebuf)));
	}

	/* Lock file for share or return false if it can't e acquired */
	flin.l_type = F_RDLCK;
	flin.l_whence = SEEK_SET;
	flin.l_start = 0;
	flin.l_len = 0;
	if (fcntl(fileno(fd_in), F_SETLK, &flin) == -1)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("can not lock file for reading \"%s\": %m",
						in_fnamebuf)));
	}

	/* Read the token information */
	nread = fread(&itoken, sizeof(struct token_data), 1, fd_in);

	/* Close the files and release the locks */
	if (fclose(fd_in) != 0)
		 ereport(ERROR,
				 (errcode_for_file_access(),
				  errmsg("could not close file \"%s\": %m", in_fnamebuf)));

	/* Check that we have read something */
        if (nread != 1) {
                ereport(ERROR,
                                (errcode_for_file_access(),
                                 errmsg("could not read server file \"%s\": %m",
                                                in_fnamebuf)));
	}
	if ( !haswrite && strcmp(itoken.mode, "R") == 0 )
		allowed = true;
	if ( haswrite && strcmp(itoken.mode, "W") == 0 )
		allowed = true;

        if (!allowed)
	{
		status = "writing";
		if (!haswrite)
			status = "reading";

                elog(WARNING,
			 "attempt to access file \"%s\" for %s without a valid token \"%s\", mode was %s",
					in_fnamebuf, status, itoken.dlpath, itoken.mode);
		PG_RETURN_NULL();
	}

	/* check that this is a transaction in progess */
	if (itoken.txid != InvalidTransactionId)
	{
		status = NULL;
		LWLockAcquire(CLogTruncationLock, LW_SHARED);
		if (TransactionIdIsCurrentTransactionId(itoken.txid))
			status = "in progress";
		else if (TransactionIdDidCommit(itoken.txid))
			status = "committed";
		else if (TransactionIdDidAbort(itoken.txid))
			status = "aborted";
		else
		{
			if (TransactionIdPrecedes(itoken.txid, GetActiveSnapshot()->xmin))
				status = "aborted";
			else
				status = "in progress";
		}
		LWLockRelease(CLogTruncationLock);

		/* Check that there is a transaction in progress */
		if (strcmp(status, "in progress") != 0)
			PG_RETURN_NULL();
	}

	PG_RETURN_TEXT_P(cstring_to_text(itoken.dlpath));
}

/* Function used to test if a file is a symlink */
PG_FUNCTION_INFO_V1(datalink_is_symlink);
Datum
datalink_is_symlink(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	char    src_fnamebuf[MAXPGPATH];
	struct stat buf;

	text_to_cstring_buffer(src, src_fnamebuf, sizeof(src_fnamebuf));

	if (lstat(src_fnamebuf, &buf) < 0)
	{
		if (errno != ENOENT)
			ereport(ERROR, (
				errmsg("could not stat file \"%s\": %s",
						src_fnamebuf, strerror(errno))));
	}

	if (S_ISLNK(buf.st_mode))
		PG_RETURN_INT32(true);

	PG_RETURN_INT32(false);
}

/* Return the target file path of a symlink */
PG_FUNCTION_INFO_V1(datalink_symlink_target);
Datum
datalink_symlink_target(PG_FUNCTION_ARGS)
{
	text    *src = PG_GETARG_TEXT_PP(0);
	char    src_fnamebuf[MAXPGPATH];
	char    target[MAXPGPATH];
	struct stat buf;

	text_to_cstring_buffer(src, src_fnamebuf, sizeof(src_fnamebuf));

	if (lstat(src_fnamebuf, &buf) < 0)
	{
		if (errno != ENOENT)
			ereport(ERROR, (
				errmsg("could not stat file \"%s\": %s",
						src_fnamebuf, strerror(errno))));
	}

	/* Get target file path */
	if (S_ISLNK(buf.st_mode))
	{
		ssize_t len;
		len = readlink(src_fnamebuf, target, sizeof(target)-1);
		if (len == -1)
			ereport(ERROR, (
				errmsg("could not get target file path for \"%s\": %s",
						src_fnamebuf, strerror(errno))));
		target[len] = '\0';
		PG_RETURN_TEXT_P(cstring_to_text(target));
	}

	PG_RETURN_NULL();
}

