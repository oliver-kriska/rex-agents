// Test stand-in for claude / amp. Never talks to anything; pauses until killed.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <libgen.h>
static void uuid(char *out, unsigned seed) {
  srand(seed ^ (unsigned)getpid());
  const char *h = "0123456789abcdef"; int k = 0;
  for (int i = 0; i < 36; i++) out[k++] = (i==8||i==13||i==18||i==23) ? '-' : h[rand()%16];
  out[k] = 0;
}
int main(int argc, char **argv) {
  char *prog = basename(argv[0]);
  char id[64] = {0};
  printf("FAKE %s pid=%d argv:", prog, getpid());
  for (int i = 1; i < argc; i++) printf(" [%s]", argv[i]);
  printf("\n");
  printf("hub=%s\n", getenv("HUB_NAME") ? getenv("HUB_NAME") : "-");
  if (strcmp(prog, "hub-server") == 0 && argc > 3) {
    sleep(2); // a foreground process exists before its readiness path does
    close(open(argv[3], O_CREAT | O_WRONLY, 0600));
  }
  const char *events = getenv("FAKE_EVENTS");
  if (events) {
    int fd = open(events, O_CREAT | O_WRONLY | O_APPEND, 0600);
    dprintf(fd, "%s\n", prog);
    close(fd);
  }
  if (strcmp(prog, "claude") == 0 && getenv("FAKE_RELAUNCH")) {
    // like Claude Code after /restart or an update: this process stays, the session runs in a child
    unsetenv("FAKE_RELAUNCH");
    pid_t c = fork();
    if (c == 0) { execvp(argv[0], argv); _exit(127); }
    printf("relaunched child=%d\n", c);
    fflush(stdout);
    for (;;) pause();
  }
  if (strcmp(prog, "claude") == 0) {
    const char *delay = getenv("FAKE_SESSION_DELAY");
    if (delay) sleep((unsigned)atoi(delay));
    for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "--resume")) snprintf(id, sizeof id, "%s", argv[i+1]);
    if (!id[0]) uuid(id, 1);
    const char *dir = getenv("REX_AGENTS_CLAUDE_SESSIONS");
    const char *st = getenv("FAKE_STATUS"); if (!st) st = "idle";
    char p[1024]; snprintf(p, sizeof p, "%s/%d.json", dir, getpid());
    FILE *f = fopen(p, "w");
    const char *nm = getenv("FAKE_NAME"), *ns = getenv("FAKE_NAME_SOURCE");
    fprintf(f, "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"status\":\"%s\"", getpid(), id, getcwd(NULL,0), st);
    if (nm) fprintf(f, ",\"name\":\"%s\",\"nameSource\":\"%s\"", nm, ns ? ns : "user");
    fprintf(f, getenv("FAKE_BROKEN") ? "}}\n" : "}\n"); // FAKE_BROKEN: a stray "}" like Claude Code issue #104810
    fclose(f);
    printf("session %s\n", id);
  } else if (strcmp(prog, "amp") == 0) {
    int runner = 0;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--no-tui")) runner = 1;
    for (int i = 1; i + 2 < argc; i++) if (!strcmp(argv[i], "threads") && !strcmp(argv[i+1], "continue")) snprintf(id, sizeof id, "%s", argv[i+2]);
    if (!runner) {
      if (!id[0]) { char u[40]; uuid(u, 2); snprintf(id, sizeof id, "T-%s", u); }
      const char *dir = getenv("FAKE_AMP_DIR");
      char p[1024]; snprintf(p, sizeof p, "%s/threads/%s.log", dir, id);
      int fd = open(p, O_CREAT | O_WRONLY | O_APPEND, 0600);
      dprintf(fd, "open\n");
      printf("thread %s\n", id);
    }
  }
  fflush(stdout);
  for (;;) pause();
}
