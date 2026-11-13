#ifndef DRANIK_NATIVE_H
#define DRANIK_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Independently authored PowerUI bridge. No private framework headers required.
 * All calls are synchronous: invoke in a disposable helper with a process timeout.
 * No initialization, capability read, or snapshot performs a write.
 * On success return 1; on failure return 0 with an optional allocated error.
 * Free every returned string (including snapshot JSON) with dn_native_free.
 * Output pointers must be non-null and are initialized before use.
 */
int dn_native_snapshot(char **json, char **error);
/* Root only. Advertised slider targets use PowerUI. Other targets in 50...99
 * use macOS 27 root/currentUser/anyHost preferences; 100 disables the limit.
 * Success means accepted, not verified. Caller must read back and persist its
 * original enabled/target policy BEFORE invoking any mutation.
 */
int dn_native_request_limit(int limit, char **error);
int dn_native_disable_limit(char **error);
void dn_native_free(char *value);

#ifdef __cplusplus
}
#endif
#endif
