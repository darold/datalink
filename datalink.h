/*
 * datalink.h
 *
 * Hearder file for the PostgreSQL Datalink extension.
 *
 * This program is open source, licensed under the PostgreSQL license.
 * For license terms, see the COPYING file.
 *
 * Copyright (c) 2019 Gilles Darold
 */

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>

/*
 * GUC datalink.dl_naptime
 * Default value for wait time between each bgworker iteration.
 * The minimum and maximum allowed time between two awakenings of the worker
 */
#define DEFAULT_DL_SLEEPTIME 10    /* second */
#define MIN_DL_SLEEPTIME 1    /* second */
#define MAX_DL_SLEEPTIME 60  /* seconds */

/*
 * GUC datalink.dl_base_directory
 * Specify the path where external files can be found for default base
 * directory FILE. Default to /var/lib/datalink/pg_external_files/.
 * This directory shall be a link to a mount point where external files
 * are available.
 */
/* #define DATALINK_DEFAULT_BASE    "/var/lib/datalink/pg_external_files" */
#define DATALINK_DEFAULT_BASE    "/tmp/test_datalink"


/*
 * GUC datalink.dl_token_path
 * Specify the path where external files can be found for default base
 * directory FILE. Default to pg_dltoken/ in the PGDATA directory.
 * This directory shall be a link to a mount point where external files
 * are available.
 */
/* #define DATALINK_TOKEN_PATH    "pg_dltoken" */
#define DATALINK_TOKEN_PATH    "/tmp/test_datalink/pg_dltoken"

/*
 * GUC datalink.dl_token_expire_after
 * Specifies the interval of time in seconds for the validity of an access
 * control token. The Datalink extension checks the validity of token by
 * comparing the creation time of the token file against this expiry time.
 * The default value for this parameter is 60 seconds. The value must be
 * upper than 0. This parameter applies to the DATALINK columns that specify
 * the "READ PERMISSION DB" and "WRITE PERMISSION ADMIN" attribute. 
 */
#define DATALINK_TOKEN_EXPIRY  60

/*
 * GUC datalink.dl_keep_max_copies
 * This configuration directive set the maximum number of copies to keep
 * in the base directories before bein removed. As we use copy on write,
 * we can not stored indefinitively the files, they must be archived on
 * an other server if you want to keep the obsolete files. Default is 5
 * copies. A value of 0 mean never detete any copies. This parameter applies
 * to the DATALINK columns that specify the "FILE LINK CONTROL" attribute. 
 */
#define DATALINK_KEEP_MAX_COPIES  5

#define BUFFER_SIZE 8192

/* Struct used to srore information about token */
typedef struct token_data {
	char mode[1];
	TransactionId txid;
	char dlpath[4096];
} token_data;

