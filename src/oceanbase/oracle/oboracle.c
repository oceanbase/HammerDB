/* OceanBase Oracle-mode Tcl binding to the official libobclient C API.
 * Compile against libobclient's headers, not the MySQL/MariaDB ABI: MYSQL,
 * MYSQL_BIND and Oracle parameter metadata have vendor-specific layouts.
 */
#include <tcl.h>
#include <mysql.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

typedef struct Driver Driver;
typedef struct Connection Connection;
typedef struct Cursor Cursor;
struct Driver { Tcl_Encoding utf8; unsigned long serial; Connection *connections; };
struct Connection {
    Driver *driver;
    MYSQL *mysql;
    Tcl_Command command;
    Tcl_Interp *interp;
    Connection *next;
    Cursor *cursors;
    Cursor *active;
};
struct Cursor {
    Connection *connection;
    Tcl_Command command;
    Cursor *next;
    MYSQL_STMT *statement;
    MYSQL_RES *result;
    Tcl_Obj *output;
    Tcl_Size position;
    Tcl_WideInt rows;
    unsigned int code;
    Tcl_Obj *message;
};
static Tcl_Mutex libraryMutex;
static int libraryInitialized;
static Tcl_ThreadDataKey threadKey;

static void ThreadExit(void *unused) { (void)unused; mysql_thread_end(); }
static void DriverDelete(void *data, Tcl_Interp *interp) {
    Driver *driver = data;
    while (driver->connections) Tcl_DeleteCommandFromToken(interp, driver->connections->command);
    Tcl_FreeEncoding(driver->utf8);
    Tcl_Free(driver);
}
static Tcl_Obj *FromUtf8(Driver *driver, const char *value, unsigned long length) {
    Tcl_DString text;
    Tcl_ExternalToUtfDString(driver->utf8, value, (Tcl_Size)length, &text);
    Tcl_Obj *result = Tcl_NewStringObj(Tcl_DStringValue(&text), Tcl_DStringLength(&text));
    Tcl_DStringFree(&text);
    return result;
}
static const char *ToUtf8(Driver *driver, Tcl_Obj *value, Tcl_DString *text) {
    Tcl_Size length;
    const char *string = Tcl_GetStringFromObj(value, &length);
    return Tcl_UtfToExternalDString(driver->utf8, string, length, text);
}
static int Error(Tcl_Interp *interp, Cursor *cursor, unsigned int code, const char *message) {
    Tcl_Obj *text = Tcl_NewStringObj(message, -1);
    if (cursor) {
        cursor->code = code;
        Tcl_DecrRefCount(cursor->message);
        cursor->message = text;
        Tcl_IncrRefCount(text);
    }
    Tcl_SetObjResult(interp, text);
    Tcl_Obj *errorCode = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(interp, errorCode, Tcl_NewStringObj("OBCLIENT", -1));
    Tcl_ListObjAppendElement(interp, errorCode, Tcl_NewIntObj((int)code));
    Tcl_SetObjErrorCode(interp, errorCode);
    return TCL_ERROR;
}
static int StatementError(Tcl_Interp *interp, Cursor *cursor) {
    return Error(interp, cursor, mysql_stmt_errno(cursor->statement), mysql_stmt_error(cursor->statement));
}
static void FreeOutput(Cursor *cursor) {
    if (cursor->output) { Tcl_DecrRefCount(cursor->output); cursor->output = NULL; }
    cursor->position = 0;
}
static void DiscardResult(Cursor *cursor) {
    if (cursor->result) { mysql_free_result(cursor->result); cursor->result = NULL; }
    if (cursor->connection->active == cursor) cursor->connection->active = NULL;
    FreeOutput(cursor);
}
static void DiscardActive(Connection *connection) {
    if (connection->active) DiscardResult(connection->active);
}
static void ResetStatus(Cursor *cursor) {
    cursor->code = 0;
    cursor->rows = 0;
    Tcl_DecrRefCount(cursor->message);
    cursor->message = Tcl_NewObj();
    Tcl_IncrRefCount(cursor->message);
}
static void CursorDelete(void *data) {
    Cursor *cursor = data;
    DiscardResult(cursor);
    if (cursor->statement) mysql_stmt_close(cursor->statement);
    Cursor **link = &cursor->connection->cursors;
    while (*link != cursor) link = &(*link)->next;
    *link = cursor->next;
    Tcl_DecrRefCount(cursor->message);
    Tcl_Free(cursor);
}
static void ConnectionDelete(void *data) {
    Connection *connection = data;
    while (connection->cursors) Tcl_DeleteCommandFromToken(connection->interp, connection->cursors->command);
    mysql_close(connection->mysql);
    Connection **link = &connection->driver->connections;
    while (*link != connection) link = &(*link)->next;
    *link = connection->next;
    Tcl_Free(connection);
}

/* PL/SQL returns only OUT/INOUT fields. Consume all its result sets now so
 * another prepared cursor on this connection can execute after one fetch.
 * TPROC-H SELECTs use the separate streaming text-query path below.
 */
static int ReadPreparedResults(Tcl_Interp *interp, Cursor *cursor) {
    MYSQL_STMT *statement = cursor->statement;
    Tcl_Obj *rows = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(rows);
    int status = TCL_OK;
    do {
        unsigned int count = mysql_stmt_field_count(statement);
        if (count) {
            MYSQL_BIND *bindings = Tcl_Alloc(sizeof(*bindings) * count);
            unsigned long *lengths = Tcl_Alloc(sizeof(*lengths) * count);
            my_bool *nulls = Tcl_Alloc(sizeof(*nulls) * count);
            char *buffers = Tcl_Alloc(4096 * (size_t)count);
            memset(bindings, 0, sizeof(*bindings) * count);
            memset(lengths, 0, sizeof(*lengths) * count);
            memset(nulls, 0, sizeof(*nulls) * count);
            for (unsigned int i = 0; i < count; ++i) {
                bindings[i].buffer_type = MYSQL_TYPE_STRING;
                bindings[i].buffer = buffers + 4096 * (size_t)i;
                bindings[i].buffer_length = 4096;
                bindings[i].length = lengths + i;
                bindings[i].is_null = nulls + i;
            }
            if (mysql_stmt_bind_result(statement, bindings)) status = StatementError(interp, cursor);
            while (status == TCL_OK) {
                int fetched = mysql_stmt_fetch(statement);
                if (fetched == MYSQL_NO_DATA) break;
                if (fetched != 0 && fetched != MYSQL_DATA_TRUNCATED) {
                    status = StatementError(interp, cursor);
                    break;
                }
                Tcl_Obj *row = Tcl_NewListObj(0, NULL);
                Tcl_IncrRefCount(row);
                for (unsigned int i = 0; i < count; ++i) {
                    Tcl_Obj *value;
                    if (nulls[i]) value = Tcl_NewObj();
                    else if (lengths[i] <= 4096) value = FromUtf8(cursor->connection->driver, bindings[i].buffer, lengths[i]);
                    else {
                        char *large = Tcl_Alloc(lengths[i]);
                        MYSQL_BIND column = bindings[i];
                        column.buffer = large;
                        column.buffer_length = lengths[i];
                        if (mysql_stmt_fetch_column(statement, &column, i, 0)) {
                            Tcl_Free(large);
                            status = StatementError(interp, cursor);
                            break;
                        }
                        value = FromUtf8(cursor->connection->driver, large, lengths[i]);
                        Tcl_Free(large);
                    }
                    Tcl_ListObjAppendElement(interp, row, value);
                }
                if (status == TCL_OK) Tcl_ListObjAppendElement(interp, rows, row);
                Tcl_DecrRefCount(row);
            }
            mysql_stmt_free_result(statement);
            Tcl_Free(buffers); Tcl_Free(nulls); Tcl_Free(lengths); Tcl_Free(bindings);
            if (status != TCL_OK) break;
        }
        int next = mysql_stmt_next_result(statement);
        if (next == -1) break;
        if (next != 0) { status = StatementError(interp, cursor); break; }
    } while (1);
    if (status == TCL_OK) cursor->output = rows;
    else { Tcl_DecrRefCount(rows); mysql_stmt_reset(statement); }
    return status;
}
static int Execute(Tcl_Interp *interp, Cursor *cursor, Tcl_Obj *values) {
    if (!cursor->statement) return Error(interp, cursor, 0, "Prepare the cursor before executing bindings");
    Tcl_Size count;
    Tcl_Obj **items;
    if (Tcl_ListObjGetElements(interp, values, &count, &items) != TCL_OK) return TCL_ERROR;
    if ((unsigned long)count != mysql_stmt_param_count(cursor->statement))
        return Error(interp, cursor, 0, "Parameter count does not match the prepared statement");
    DiscardActive(cursor->connection);
    DiscardResult(cursor);
    ResetStatus(cursor);
    MYSQL_BIND *bindings = Tcl_Alloc(sizeof(*bindings) * (size_t)(count + 1));
    Tcl_DString *strings = Tcl_Alloc(sizeof(*strings) * (size_t)(count + 1));
    unsigned long *lengths = Tcl_Alloc(sizeof(*lengths) * (size_t)(count + 1));
    my_bool *nulls = Tcl_Alloc(sizeof(*nulls) * (size_t)(count + 1));
    memset(bindings, 0, sizeof(*bindings) * (size_t)(count + 1));
    for (Tcl_Size i = 0; i < count; ++i) {
        bindings[i].buffer_type = MYSQL_TYPE_STRING;
        bindings[i].buffer = (void *)ToUtf8(cursor->connection->driver, items[i], strings + i);
        lengths[i] = (unsigned long)Tcl_DStringLength(strings + i);
        nulls[i] = lengths[i] == 0; /* Oracle treats the empty string as NULL. */
        bindings[i].buffer_length = lengths[i];
        bindings[i].length = lengths + i;
        bindings[i].is_null = nulls + i;
    }
    int failed = (count && mysql_stmt_bind_param(cursor->statement, bindings)) || mysql_stmt_execute(cursor->statement);
    int status;
    if (failed) {
        status = StatementError(interp, cursor);
        mysql_stmt_reset(cursor->statement); /* Preserve the handle for the next transaction. */
    } else {
        my_ulonglong affected = mysql_stmt_affected_rows(cursor->statement);
        cursor->rows = affected == (my_ulonglong)-1 ? 0 : (Tcl_WideInt)affected;
        status = ReadPreparedResults(interp, cursor);
    }
    for (Tcl_Size i = 0; i < count; ++i) Tcl_DStringFree(strings + i);
    Tcl_Free(nulls); Tcl_Free(lengths); Tcl_Free(strings); Tcl_Free(bindings);
    if (status == TCL_OK) Tcl_SetObjResult(interp, Tcl_NewWideIntObj(cursor->rows));
    return status;
}
static int CursorCommand(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Cursor *cursor = data;
    Connection *connection = cursor->connection;
    static const char *const methods[] = {"prepare", "execute", "query", "fetch", "status", "close", NULL};
    enum {PREPARE, EXECUTE, QUERY, FETCH, STATUS, CLOSE};
    int method;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "method ?arguments?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], methods, "method", TCL_EXACT, &method) != TCL_OK) return TCL_ERROR;
    int expected = method <= QUERY ? 3 : 2;
    if (objc != expected) { Tcl_WrongNumArgs(interp, 2, objv, expected == 3 ? "value" : ""); return TCL_ERROR; }
    if (method == CLOSE) { Tcl_DeleteCommandFromToken(interp, cursor->command); return TCL_OK; }
    if (method == STATUS) {
        Tcl_Obj *status = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, status, Tcl_NewStringObj("rc", -1), Tcl_NewIntObj((int)cursor->code));
        Tcl_DictObjPut(interp, status, Tcl_NewStringObj("rows", -1), Tcl_NewWideIntObj(cursor->rows));
        Tcl_DictObjPut(interp, status, Tcl_NewStringObj("message", -1), cursor->message);
        Tcl_SetObjResult(interp, status);
        return TCL_OK;
    }
    if (method == FETCH) {
        Tcl_Obj *row = NULL;
        if (cursor->result) {
            MYSQL_ROW fields = mysql_fetch_row(cursor->result);
            if (fields) {
                unsigned long *lengths = mysql_fetch_lengths(cursor->result);
                row = Tcl_NewListObj(0, NULL);
                unsigned int count = mysql_num_fields(cursor->result);
                for (unsigned int i = 0; i < count; ++i)
                    Tcl_ListObjAppendElement(interp, row, fields[i] ? FromUtf8(connection->driver, fields[i], lengths[i]) : Tcl_NewObj());
                cursor->rows++;
            } else {
                if (mysql_errno(connection->mysql)) return Error(interp, cursor, mysql_errno(connection->mysql), mysql_error(connection->mysql));
                mysql_free_result(cursor->result); cursor->result = NULL; connection->active = NULL;
            }
        } else if (cursor->output) {
            Tcl_ListObjIndex(interp, cursor->output, cursor->position++, &row);
            if (row) cursor->rows++;
        }
        cursor->code = row ? 0 : 1403;
        Tcl_Obj *result[2] = {Tcl_NewBooleanObj(row != NULL), row ? row : Tcl_NewListObj(0, NULL)};
        Tcl_SetObjResult(interp, Tcl_NewListObj(2, result));
        return TCL_OK;
    }
    if (method == EXECUTE) return Execute(interp, cursor, objv[2]);
    DiscardActive(connection);
    DiscardResult(cursor);
    ResetStatus(cursor);
    Tcl_DString sql;
    const char *text = ToUtf8(connection->driver, objv[2], &sql);
    if (method == PREPARE) {
        if (cursor->statement) mysql_stmt_close(cursor->statement);
        cursor->statement = mysql_stmt_init(connection->mysql);
        if (!cursor->statement) { Tcl_DStringFree(&sql); return Error(interp, cursor, 0, "Unable to allocate prepared statement"); }
        int failed = mysql_stmt_prepare(cursor->statement, text, (unsigned long)Tcl_DStringLength(&sql));
        Tcl_DStringFree(&sql);
        if (failed) return StatementError(interp, cursor);
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj((Tcl_WideInt)mysql_stmt_param_count(cursor->statement)));
        return TCL_OK;
    }
    int failed = mysql_real_query(connection->mysql, text, (unsigned long)Tcl_DStringLength(&sql));
    Tcl_DStringFree(&sql);
    if (failed) return Error(interp, cursor, mysql_errno(connection->mysql), mysql_error(connection->mysql));
    if (mysql_field_count(connection->mysql)) {
        cursor->result = mysql_use_result(connection->mysql);
        if (!cursor->result) return Error(interp, cursor, mysql_errno(connection->mysql), mysql_error(connection->mysql));
        connection->active = cursor;
    } else {
        cursor->rows = (Tcl_WideInt)mysql_affected_rows(connection->mysql);
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(cursor->rows));
    return TCL_OK;
}
static int ConnectionCommand(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Connection *connection = data;
    static const char *const methods[] = {"open", "autocommit", "commit", "rollback", "info", "close", NULL};
    enum {OPEN, AUTOCOMMIT, COMMIT, ROLLBACK, INFO, CLOSE};
    int method;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "method ?arguments?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], methods, "method", TCL_EXACT, &method) != TCL_OK) return TCL_ERROR;
    if (objc != (method == AUTOCOMMIT ? 3 : 2)) { Tcl_WrongNumArgs(interp, 2, objv, method == AUTOCOMMIT ? "boolean" : ""); return TCL_ERROR; }
    if (method == CLOSE) { Tcl_DeleteCommandFromToken(interp, connection->command); return TCL_OK; }
    if (method == OPEN) {
        Cursor *cursor = Tcl_Alloc(sizeof(*cursor));
        memset(cursor, 0, sizeof(*cursor));
        cursor->connection = connection;
        cursor->message = Tcl_NewObj(); Tcl_IncrRefCount(cursor->message);
        char name[80];
        snprintf(name, sizeof(name), "::oboracle::cursor%lu", ++connection->driver->serial);
        cursor->next = connection->cursors; connection->cursors = cursor;
        cursor->command = Tcl_CreateObjCommand(interp, name, CursorCommand, cursor, CursorDelete);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(name, -1));
        return TCL_OK;
    }
    if (method == INFO) {
        Tcl_Obj *info = Tcl_NewDictObj();
        const char *cipher = mysql_get_ssl_cipher(connection->mysql);
        Tcl_DictObjPut(interp, info, Tcl_NewStringObj("cipher", -1), Tcl_NewStringObj(cipher ? cipher : "", -1));
        Tcl_DictObjPut(interp, info, Tcl_NewStringObj("oracle_mode", -1), Tcl_NewBooleanObj(connection->mysql->oracle_mode));
        Tcl_DictObjPut(interp, info, Tcl_NewStringObj("client", -1), Tcl_NewStringObj(mysql_get_client_info(), -1));
        Tcl_SetObjResult(interp, info);
        return TCL_OK;
    }
    DiscardActive(connection);
    int failed;
    if (method == AUTOCOMMIT) {
        int enabled;
        if (Tcl_GetBooleanFromObj(interp, objv[2], &enabled) != TCL_OK) return TCL_ERROR;
        failed = mysql_autocommit(connection->mysql, (my_bool)enabled);
    } else if (method == COMMIT) failed = mysql_commit(connection->mysql);
    else failed = mysql_rollback(connection->mysql);
    if (failed) return Error(interp, NULL, mysql_errno(connection->mysql), mysql_error(connection->mysql));
    return TCL_OK;
}
static int ConnectCommand(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Driver *driver = data;
    if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "options"); return TCL_ERROR; }
    static const char *const names[] = {"-host", "-port", "-user", "-password", "-ssl", "-sslca", "-sslcapath", "-sslcert", "-sslkey", "-sslcipher", NULL};
    Tcl_Obj *values[10] = {0};
    Tcl_DictSearch search;
    Tcl_Obj *key, *value;
    int done;
    if (Tcl_DictObjFirst(interp, objv[1], &search, &key, &value, &done) != TCL_OK) return TCL_ERROR;
    for (; !done; Tcl_DictObjNext(&search, &key, &value, &done)) {
        int index;
        if (Tcl_GetIndexFromObj(interp, key, names, "connection option", TCL_EXACT, &index) != TCL_OK) { Tcl_DictObjDone(&search); return TCL_ERROR; }
        values[index] = value;
    }
    Tcl_DictObjDone(&search);
    if (!values[0] || !values[1] || !values[2] || !values[3] || !values[4]) return Error(interp, NULL, 0, "Connection requires host, port, user, password and ssl options");
    int port, ssl;
    if (Tcl_GetIntFromObj(interp, values[1], &port) != TCL_OK || Tcl_GetBooleanFromObj(interp, values[4], &ssl) != TCL_OK) return TCL_ERROR;
    if (port < 1 || port > 65535) return Error(interp, NULL, 0, "Invalid OceanBase port");
    Tcl_DString strings[10];
    const char *options[10] = {0};
    for (int i = 0; i < 10; ++i) {
        Tcl_DStringInit(strings + i);
        if (values[i]) {
            options[i] = ToUtf8(driver, values[i], strings + i);
            if (strlen(options[i]) != (size_t)Tcl_DStringLength(strings + i)) {
                for (int j = 0; j <= i; ++j) Tcl_DStringFree(strings + j);
                return Error(interp, NULL, 0, "NUL is not allowed in connection options");
            }
        }
    }
    MYSQL *mysql = mysql_init(NULL);
    int status = TCL_OK;
    if (!mysql) status = Error(interp, NULL, 0, "Unable to initialize libobclient");
    else {
        unsigned int timeout = 15;
        my_bool reconnect = 0, enforce = (my_bool)ssl;
        if (mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout) ||
            mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect) ||
            mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "utf8mb4") ||
            mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &enforce) ||
            (ssl && mysql_ssl_set(mysql, options[8], options[7], options[5], options[6], options[9])))
            status = Error(interp, NULL, mysql_errno(mysql), mysql_error(mysql));
        else if (!mysql_real_connect(mysql, options[0], options[2], options[3], NULL, (unsigned int)port, NULL, CLIENT_MULTI_RESULTS | CLIENT_PS_MULTI_RESULTS))
            status = Error(interp, NULL, mysql_errno(mysql), mysql_error(mysql));
        else if (!mysql->oracle_mode) status = Error(interp, NULL, 0, "The connected tenant is not in Oracle mode");
        else if (ssl && !mysql_get_ssl_cipher(mysql)) status = Error(interp, NULL, 0, "The server did not establish the requested SSL connection");
        /* Match OCI's initial manual-commit mode. The native workload enables
         * autocommit explicitly where required; its procedures own TPROC-C commits.
         */
        else if (mysql_autocommit(mysql, 0)) status = Error(interp, NULL, mysql_errno(mysql), mysql_error(mysql));
    }
    for (int i = 0; i < 10; ++i) Tcl_DStringFree(strings + i);
    if (status != TCL_OK) { if (mysql) mysql_close(mysql); return status; }
    Connection *connection = Tcl_Alloc(sizeof(*connection));
    memset(connection, 0, sizeof(*connection));
    connection->driver = driver; connection->mysql = mysql;
    connection->interp = interp;
    connection->next = driver->connections; driver->connections = connection;
    char name[80];
    snprintf(name, sizeof(name), "::oboracle::connection%lu", ++driver->serial);
    connection->command = Tcl_CreateObjCommand(interp, name, ConnectionCommand, connection, ConnectionDelete);
    Tcl_SetObjResult(interp, Tcl_NewStringObj(name, -1));
    return TCL_OK;
}
DLLEXPORT int Oboracle_Init(Tcl_Interp *interp) {
    if (!Tcl_InitStubs(interp, "9.0", 0)) return TCL_ERROR;
    Tcl_MutexLock(&libraryMutex);
    if (!libraryInitialized) {
        if (mysql_library_init(0, NULL, NULL)) { Tcl_MutexUnlock(&libraryMutex); return Error(interp, NULL, 0, "Unable to initialize libobclient library"); }
        libraryInitialized = 1;
    }
    Tcl_MutexUnlock(&libraryMutex);
    int *initialized = Tcl_GetThreadData(&threadKey, sizeof(int));
    if (!*initialized) {
        if (mysql_thread_init()) return Error(interp, NULL, 0, "Unable to initialize libobclient thread");
        *initialized = 1;
        Tcl_CreateThreadExitHandler(ThreadExit, NULL);
    }
    Driver *driver = Tcl_Alloc(sizeof(*driver));
    memset(driver, 0, sizeof(*driver));
    driver->utf8 = Tcl_GetEncoding(interp, "utf-8");
    if (!driver->utf8) { Tcl_Free(driver); return TCL_ERROR; }
    Tcl_SetAssocData(interp, "oboracle", DriverDelete, driver);
    if (!Tcl_FindNamespace(interp, "::oboracle", NULL, 0)) Tcl_CreateNamespace(interp, "::oboracle", NULL, NULL);
    Tcl_CreateObjCommand(interp, "::oboracle::connect", ConnectCommand, driver, NULL);
    return Tcl_PkgProvide(interp, "oboracle", "1.0");
}
