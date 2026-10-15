/* TLS configuration for an isolated OBCI client, not process-wide interposition.
 * Link the vendor's OCI objects with --wrap=mysql_real_connect. Other MySQL
 * clients continue to call libobclient directly. No vendor structs are accessed.
 */
#include <tcl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Public OBConnector/C ABI, include/mysql.h: opaque MYSQL plus stable options
 * MYSQL_OPT_SSL_VERIFY_SERVER_CERT=21 and MYSQL_OPT_SSL_ENFORCE=38.
 * https://github.com/oceanbase/obconnector-c/blob/master/include/mysql.h
 */
typedef struct st_mysql MYSQL;
extern int mysql_options(MYSQL *, int, const void *);
extern int mysql_ssl_set(MYSQL *, const char *, const char *, const char *, const char *, const char *);
extern const char *mysql_get_ssl_cipher(MYSQL *);
extern const char *mysql_error(MYSQL *);
extern MYSQL *__real_mysql_real_connect(MYSQL *, const char *, const char *, const char *, const char *, unsigned int, const char *, unsigned long);

static Tcl_Mutex settings_mutex;
static int configured;
static const char *keys[] = {"-sslca", "-sslcapath", "-sslcert", "-sslkey", "-sslcipher"};
static char *values[5];
static _Thread_local char last_error[512];

MYSQL *__wrap_mysql_real_connect(MYSQL *mysql, const char *host, const char *user,
        const char *password, const char *database, unsigned int port,
        const char *socket_name, unsigned long flags)
{
    char *v[5];
    int ready;
    char enforce = 1, verify;
    MYSQL *result;
    last_error[0] = '\0';
    Tcl_MutexLock(&settings_mutex);
    ready = configured;
    memcpy(v, values, sizeof(v));
    Tcl_MutexUnlock(&settings_mutex);
    if (!ready) {
        snprintf(last_error, sizeof(last_error), "OBCI TLS client was not configured");
        return NULL;
    }
    verify = (v[0] != NULL || v[1] != NULL);
    /* Apply after OBCI's own mysql_ssl_set(NULL, ...), immediately before the
     * handshake. ENFORCE prevents a server without TLS from accepting plaintext.
     */
    if (mysql_ssl_set(mysql, v[3], v[2], v[0], v[1], v[4]) ||
            mysql_options(mysql, 38, &enforce) || mysql_options(mysql, 21, &verify)) {
        snprintf(last_error, sizeof(last_error), "libobclient rejected the requested SSL options");
        return NULL;
    }
    result = __real_mysql_real_connect(mysql, host, user, password, database, port, socket_name, flags | 2048UL);
    if (!result) {
        snprintf(last_error, sizeof(last_error), "%s", mysql_error(mysql));
    } else if (!mysql_get_ssl_cipher(result) || !*mysql_get_ssl_cipher(result)) {
        snprintf(last_error, sizeof(last_error), "OBCI connection did not negotiate SSL; refusing plaintext");
        /* OBCI owns and cleans up MYSQL on its error path. */
        result = NULL;
    }
    return result;
}

static int ConfigureCmd(ClientData unused, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_DictSearch search;
    Tcl_Obj *key, *value;
    char *next[5] = {NULL, NULL, NULL, NULL, NULL};
    int done, enabled = 0, status = TCL_ERROR;
    (void)unused;
    if (objc != 2) {Tcl_WrongNumArgs(interp, 1, objv, "sslOptions"); return TCL_ERROR;}
    if (Tcl_DictObjFirst(interp, objv[1], &search, &key, &value, &done) != TCL_OK) return TCL_ERROR;
    while (!done) {
        const char *name = Tcl_GetString(key);
        Tcl_Size length;
        const char *text = Tcl_GetStringFromObj(value, &length);
        int index;
        if ((Tcl_Size)strlen(text) != length) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("NUL is not allowed in SSL options", -1));
            goto finish_search;
        }
        if (!strcmp(name, "-ssl")) {
            if (Tcl_GetBooleanFromObj(interp, value, &enabled) != TCL_OK) goto finish_search;
        } else {
            for (index = 0; index < 5 && strcmp(name, keys[index]); ++index) {}
            if (index == 5) {
                Tcl_SetObjResult(interp, Tcl_ObjPrintf("Unknown OBCI TLS option: %s", name));
                goto finish_search;
            }
            if (length) {
                next[index] = malloc((size_t)length + 1);
                if (!next[index]) {Tcl_SetObjResult(interp, Tcl_NewStringObj("Cannot allocate SSL options", -1)); goto finish_search;}
                memcpy(next[index], text, (size_t)length + 1);
            }
        }
        Tcl_DictObjNext(&search, &key, &value, &done);
    }
    if (!enabled) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("The OBCI TLS client requires SSL to be enabled", -1));
        goto finish_search;
    }
    Tcl_MutexLock(&settings_mutex);
    if (configured) {
        int equal = 1;
        for (int i = 0; i < 5; ++i) {
            if ((values[i] == NULL) != (next[i] == NULL) || (values[i] && strcmp(values[i], next[i]))) equal = 0;
        }
        if (!equal) Tcl_SetObjResult(interp, Tcl_NewStringObj("OBCI SSL settings changed after initialization; start a new HammerDB process", -1));
        else status = TCL_OK;
    } else {
        memcpy(values, next, sizeof(values));
        memset(next, 0, sizeof(next));
        configured = 1;
        status = TCL_OK;
    }
    Tcl_MutexUnlock(&settings_mutex);
finish_search:
    Tcl_DictObjDone(&search);
    for (int i = 0; i < 5; ++i) free(next[i]);
    return status;
}

static int ErrorCmd(ClientData unused, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)unused;
    if (objc != 1) {Tcl_WrongNumArgs(interp, 1, objv, ""); return TCL_ERROR;}
    Tcl_SetObjResult(interp, Tcl_NewStringObj(last_error, -1));
    return TCL_OK;
}

DLLEXPORT int Hdbobcitls_Init(Tcl_Interp *interp)
{
    if (!Tcl_InitStubs(interp, "9.0", 0)) return TCL_ERROR;
    if (!Tcl_FindNamespace(interp, "::hdbobcitls", NULL, 0) &&
            !Tcl_CreateNamespace(interp, "::hdbobcitls", NULL, NULL)) return TCL_ERROR;
    Tcl_CreateObjCommand2(interp, "::hdbobcitls::configure", ConfigureCmd, NULL, NULL);
    Tcl_CreateObjCommand2(interp, "::hdbobcitls::last_error", ErrorCmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "Hdbobcitls", "1.0");
}
