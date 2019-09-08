/*
 * datalink_bgw.c
 *
 * A background worker process for the datalink extension to allow
 * maintenance of obsolete token and symlink created for reading tables.
 * Scan the token storage directory for expired token the are not part
 * of a transaction in progress.
 *
 * This program is open source, licensed under the PostgreSQL license.
 * For license terms, see the COPYING file.
 *
 * Copyright (c) 2019 Gilles Darold
 */

#include "postgres.h"
#include "libpq-fe.h"

/* Necessary for a bgworker */
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"

/* Used by this code */
#include "access/xact.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"
#include "utils/snapmgr.h"
#include "tcop/utility.h"
#include "pgstat.h"
#include "utils/ps_status.h"
#include "catalog/pg_database.h"
#include "access/htup_details.h"
#include "utils/memutils.h"
#include "utils/varlena.h"

#include "datalink.h"

/* GUC variables */
static char *dl_base_path;
static int   dl_max_copies;
static int   dl_naptime;
static char *dl_token_path;
static int   dl_token_expiry;

void _PG_init(void);
void datalink_bgw_main(Datum main_arg) ;
bool process_expired_token(char *token_str);

/* flags set by signal handlers */
static volatile sig_atomic_t got_sighup = false;
static volatile sig_atomic_t got_sigterm = false;

/* Counter of iteration */
static int iteration = 0;

/*
 * Signal handler for SIGTERM
 *      Set a flag to let the main loop to terminate, and set our latch to wake
 *      it up.
 */
static void
datalink_bgw_sigterm(SIGNAL_ARGS)
{
	int         save_errno = errno;

	got_sigterm = true;

	if (MyProc)
		SetLatch(&MyProc->procLatch);

	errno = save_errno;
}

/*
 * Signal handler for SIGHUP
 *      Set a flag to tell the main loop to reread the config file, and set
 *      our latch to wake it up.
 */
static void
datalink_bgw_sighup(SIGNAL_ARGS)
{
	int         save_errno = errno;

	got_sighup = true;

	if (MyProc)
		SetLatch(&MyProc->procLatch);

	errno = save_errno;
}

/*
 * Entrypoint of this module.
 */
void
_PG_init(void)
{
	BackgroundWorker worker;

	DefineCustomIntVariable("datalink.dl_naptime",
				"How often maintenance of datalink is called (in seconds).",
				NULL,
				&dl_naptime,
				DEFAULT_DL_SLEEPTIME,
				MIN_DL_SLEEPTIME,
				MAX_DL_SLEEPTIME,
				PGC_SIGHUP,
				0,
				NULL,
				NULL,
				NULL);


	DefineCustomIntVariable("datalink.dl_token_expiry",
				"Interval of time in seconds for the validity of an access control token.",
				NULL,
				&dl_token_expiry,
				DATALINK_TOKEN_EXPIRY,
				1,
				INT_MAX,
				PGC_SIGHUP,
				0,
				NULL,
				NULL,
				NULL);

	DefineCustomStringVariable("datalink.dl_base_directory",
				"Specify the path where external files can be found for default base directory FILE.",
				NULL,
				&dl_base_path,
				DATALINK_DEFAULT_BASE,
				PGC_SIGHUP,
				0,
				NULL,
				NULL,
				NULL);

	DefineCustomStringVariable("datalink.dl_token_path",
				"Specify the path where token files are stored.",
				NULL,
				&dl_token_path,
				DATALINK_TOKEN_PATH,
				PGC_SIGHUP,
				0,
				NULL,
				NULL,
				NULL);

	DefineCustomIntVariable("datalink.dl_keep_max_copies",
				"This configuration directive set the maximum number of copies to keep in the base directories before bein removed.",
				NULL,
				&dl_max_copies,
				DATALINK_KEEP_MAX_COPIES,
				1,
				INT_MAX,
				PGC_SIGHUP,
				0,
				NULL,
				NULL,
				NULL);

	if (!process_shared_preload_libraries_in_progress)
		return;

	/* Start when database starts */
	sprintf(worker.bgw_name, "Datalink background worker");
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 600; /* Restart after 10min in case of crash */
	sprintf(worker.bgw_library_name, "datalink_bgw");
	sprintf(worker.bgw_function_name, "datalink_bgw_main");
	worker.bgw_main_arg = (Datum) 0;
	worker.bgw_notify_pid = 0;
	RegisterBackgroundWorker(&worker);

}

void
datalink_bgw_main(Datum main_arg)
{
	int            worker_id = DatumGetInt32(main_arg); /* in case we start mulitple worker at startup */

	ereport(LOG,
			(errmsg("Datalink background worker started (#%d)", worker_id)));
	
	/* Establish signal handlers before unblocking signals. */
	pqsignal(SIGHUP, datalink_bgw_sighup);
	pqsignal(SIGTERM, datalink_bgw_sigterm);

	/* We're now ready to receive signals */
	BackgroundWorkerUnblockSignals();

	/*
	 * Main loop: do this until the SIGTERM handler tells us to terminate
	 */
	while (!got_sigterm)
	{
		DIR *d;
		struct dirent *dir;
		int             rc;

		/* Using Latch loop method suggested in latch.h
		 * Uses timeout flag in WaitLatch() further below instead of sleep to allow clean shutdown */
		ResetLatch(&MyProc->procLatch);

		CHECK_FOR_INTERRUPTS();

		/* In case of a SIGHUP, just reload the configuration. */
		if (got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/* Get the list of token files to check */
		d = opendir(dl_token_path);
		if (d)
		{
			while ((dir = readdir(d)) != NULL)
			{
				if (dir->d_type == DT_REG)
				{
					/*
					 * Check for validity of the token.
					 * If delta creation time is > dl_token_expiry th token can be removed
					 * only if the transaction is not in progress.
					 */
					if (process_expired_token(dir->d_name))
						elog(LOG, "token file %s has expired", dir->d_name);
				}
			}
			closedir(d);
		}

		iteration++;

		ereport(DEBUG1,
				(errmsg("Latch status before waitlatch call: %d", MyProc->procLatch.is_set)));

		rc = WaitLatch(&MyProc->procLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   dl_naptime * 1000L,
					   PG_WAIT_EXTENSION);

		/* emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		ereport(DEBUG1,
				(errmsg("Latch status after waitlatch call: %d", MyProc->procLatch.is_set)));
	} /* End of main loop */
}

/*
 * Check for validity of the token and remove files if required.
 * If delta creation time is > dl_token_expiry the token can be removed only
 * if the transaction is not in progress. Remove the copy of the external file
 * for a write token when the transaction is aborted. Remove the symlink to
 * external file for a read token whatever the transaction have been aborted
 * or committed. Return true if the expired token has been removed, false when
 * nothing have been done.
 */
bool
process_expired_token(char *token_str)
{
	FILE    *fd_in;
	int     nread;
	char    in_fnamebuf[MAXPGPATH];
	bool    write_token = false;
	struct  stat fst;
	time_t  curtime;
	const char *status;
	struct token_data token;

	/* Open the token file */
	snprintf(in_fnamebuf, sizeof(in_fnamebuf), "%s/%s", dl_token_path, token_str);

	/* First check if the token has expired */
	if (stat(in_fnamebuf, &fst) == -1)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("can not stat file \"%s\": %m", in_fnamebuf)));
	curtime = time(NULL);
	/*
	 * When it is still valid there is nothing more to do even if the transaction
	 * have been aborted, we will check it next time when the token will expire.
	 */
	if (curtime - fst.st_ctime < dl_token_expiry)
		return false;

	/* Look at file content to extract the transaction id and the path to the external file */
	fd_in = fopen(in_fnamebuf, "r");
	if (!fd_in) {
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not open server file \"%s\": %m",
						in_fnamebuf)));
	}

	/* Read the token information */
	nread = fread(&token, sizeof(struct token_data), 1, fd_in);
	if ( strcmp(token.mode, "R") == 0 )
		write_token = false;
	if ( strcmp(token.mode, "W") == 0 )
		write_token = true;

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

	/* check that this is a transaction in progess */
	if (token.txid != InvalidTransactionId)
	{
		status = NULL;
		LWLockAcquire(CLogTruncationLock, LW_SHARED);
		if (TransactionIdIsCurrentTransactionId(token.txid))
			status = "in progress";
		else if (TransactionIdDidCommit(token.txid))
			status = "committed";
		else if (TransactionIdDidAbort(token.txid))
			status = "aborted";
		else
		{
			if (TransactionIdPrecedes(token.txid, GetActiveSnapshot()->xmin))
				status = "aborted";
			else
				status = "in progress";
		}
		LWLockRelease(CLogTruncationLock);

		/* When the transaction is in progress do nothing */
		if (strcmp(status, "in progress") == 0)
			return false;
		/*
		 * The transaction has been aborted and this was a write token
		 * remove the external file copy, it will not be used any more.
		 */
		if (write_token && strcmp(status, "aborted") == 0)
		{
			/* Remove external file */
			if (unlink(token.dlpath) != 0 && errno != ENOENT)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not remove external file \"%s\": %m", token.dlpath)));
		}
		/* For a read token we remove the symlink whatever is the transation state */
		if (!write_token)
		{
			/* Remove symlink */
			if (unlink(token.dlpath) != 0 && errno != ENOENT)
				ereport(ERROR,
						(errcode_for_file_access(),
						 errmsg("could not remove symlink \"%s\": %m", token.dlpath)));
		}
		/* Now remove the token file it will not be used anymore */
		if (unlink(in_fnamebuf) != 0 && errno != ENOENT)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not remove token file \"%s\": %m", in_fnamebuf)));
		/* log a warning to warn that a token has expired */
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("token \"%s\" to access file \"%s\" has expired, %ld seconds after its creation",
						token_str, in_fnamebuf, curtime - fst.st_ctime)));
	}
	else
	{
		ereport(ERROR,
				(errcode(ERRCODE_NO_ACTIVE_SQL_TRANSACTION),
				 errmsg("invalid Datalink token access control in file \"%s\"", in_fnamebuf)));
	}

	return true;
}

