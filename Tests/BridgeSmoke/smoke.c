// Loads a project through the C bridge, plays it, and checks the scene. Usage: smoke <project.pcc>
#include "wirebench_bridge.h"
#include <stdio.h>
#include <string.h>

static int count(const char *haystack, const char *needle) {
    int n = 0;
    for (const char *p = haystack; (p = strstr(p, needle)); p += strlen(needle)) n++;
    return n;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    WirebenchSession *s = wirebench_create();
    char command[2048];
    snprintf(command, sizeof command, "{\"cmd\":\"open\",\"path\":\"%s\"}", argv[1]);
    char *reply = wirebench_command(s, command);
    printf("open: %s\n", reply);
    int opened = strstr(reply, "true") != NULL;
    wirebench_free(reply);
    if (!opened) return 1;

    char *scene = wirebench_scene(s);
    int modules = count(scene, "\"inPins\"");
    int wires = count(scene, "\"outModule\"");
    printf("modules=%d wires=%d\n", modules, wires);
    wirebench_free(scene);
    if (modules == 0) return 1;

    wirebench_free(wirebench_command(s, "{\"cmd\":\"play\"}"));
    int changes = 0;
    for (int i = 0; i < 400; i++) changes += wirebench_tick(s, 16.0);
    scene = wirebench_scene(s);
    int playing = strstr(scene, "\"playing\":true") != NULL;
    printf("playing=%d changes=%d\n", playing, changes);
    wirebench_free(scene);

    reply = wirebench_command(s, "{\"cmd\":\"palette\",\"query\":\"and\"}");
    int blocks = count(reply, "\"guid\"");
    printf("palette(and)=%d\n", blocks);
    wirebench_free(reply);

    // Uploading with no PLC connected is refused with a message (a task is not started); the host also pumps the main
    // queue, as it must for a real upload, which is a Swift task on the main actor.
    wirebench_free(wirebench_command(s, "{\"cmd\":\"upload\"}"));
    int finished = 0;
    for (int i = 0; i < 300 && !finished; i++) {
        wirebench_pump();
        scene = wirebench_scene(s);
        finished = strstr(scene, "No serial link") != NULL;
        wirebench_free(scene);
    }
    scene = wirebench_scene(s);
    const char *hardware = strstr(scene, "\"hardware\"");
    if (!finished && hardware) printf("hardware: %.400s\n", hardware);
    wirebench_free(scene);
    printf("upload ran=%d\n", finished);

    reply = wirebench_command(s, "{\"cmd\":\"build\"}");
    int built = strstr(reply, "\"compiled\"") != NULL;
    printf("build=%d\n", built);
    wirebench_free(reply);
    wirebench_destroy(s);
    return playing && blocks > 0 && finished && built ? 0 : 1;
}
