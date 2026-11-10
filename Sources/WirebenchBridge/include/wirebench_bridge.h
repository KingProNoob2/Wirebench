// The C interface to the Dirigo application model, for a frontend written in another language.
//
// Everything runs on the caller's thread, which must be the same one every time (the frontend's main thread). Strings
// in and out are UTF-8; every returned string is allocated by the bridge and must be released with `wirebench_free`.
// State comes out as JSON (`wirebench_scene`), changes go in as JSON commands (`wirebench_command`).
#ifndef WIREBENCH_BRIDGE_H
#define WIREBENCH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WirebenchSession WirebenchSession;

WirebenchSession *wirebench_create(void);
void wirebench_destroy(WirebenchSession *session);
void wirebench_free(char *string);

// The current page as JSON: modules with pin labels and live values, routed wires, pages, play state.
char *wirebench_scene(WirebenchSession *session);

// Runs one command, given as a JSON object with a "cmd" member, and returns a JSON object with "ok" (and, for queries,
// the result). Commands: open, save, new, play, pause, step, reset, undo, redo, select, move, addBlock, delete,
// connect, disconnect, setPage, setInput, palette. See bridge_commands for the arguments of each.
char *wirebench_command(WirebenchSession *session, const char *json);

// For the frontend's timer: advances the simulation by `elapsed_ms` of wall-clock time while playing. Returns 1 when
// something visible changed since the last call to `wirebench_scene`, else 0.
int wirebench_tick(WirebenchSession *session, double elapsed_ms);

// How many cycles the simulation has run. Cheap, unlike `wirebench_scene`, which a frontend only fetches when a value changed.
unsigned long long wirebench_tick_count(WirebenchSession *session);

// Lets queued main-actor work (an upload) advance. Call it from the frontend's timer, on the same thread.
void wirebench_pump(void);

#ifdef __cplusplus
}
#endif
#endif
