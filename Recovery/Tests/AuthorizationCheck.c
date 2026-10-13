#include "../Native/Authorization.c"
#include <assert.h>
#include <stdio.h>
static char latest[LOG_LIMIT*10+64];
static void password_mode(void) {
    struct termios term;
    assert(tcgetattr(STDIN_FILENO,&term)==0);
    term.c_lflag &= ~(ECHO|ECHONL);
    assert(tcsetattr(STDIN_FILENO,TCSAFLUSH,&term)==0);
}
static void capture(const char *text, void *context) {
    (void)context;
    assert(!strstr(text,"fixture-password"));
    assert(!strstr(text,"fixture-pass"));
    snprintf(latest,sizeof(latest),"%s",text);
}
int main(int argc, char **argv)
{
    if (argc > 1) {
        char user[128], password[128], confirmation[16];
        if (!strcmp(argv[1], "--getpass")) {
            alarm(3);
            fputs("Username: ", stderr); fflush(stderr);
            if (!fgets(user,sizeof(user),stdin)) return 20;
            const char *secret=getpass("Password: ");
            return strcmp(user,"fixture-user\n") || !secret || strcmp(secret,"fixture-password") ? 21 : 0;
        }

        if (!strncmp(argv[1], "--native-confirm", 16)) {
            const char *prompt="Are you sure you want to do this? (enter y or n)\r\n";
            alarm(3); /* Bound the regression when an old matcher misses it. */
            if (!strcmp(argv[1], "--native-confirm-split")) {
                for (const char *p=prompt; *p; p++) { putchar(*p); fflush(stdout); usleep(1000); }
            } else { printf("%s",prompt); fflush(stdout); }
            if (!fgets(confirmation,sizeof(confirmation),stdin)) return 12;
            if (strcmp(confirmation,"y\n")) return 13;
            if (!strcmp(argv[1], "--native-confirm-again")) {
                printf("%s",prompt); fflush(stdout);
                if (!fgets(confirmation,sizeof(confirmation),stdin)) return 14;
                return 15;
            }
        }
        if (!strcmp(argv[1], "--confirm") || !strcmp(argv[1], "--confirm-again")) {
            printf("Confirm custom boot object? [y/"); fflush(stdout); usleep(20000);
            printf("N]: "); fflush(stdout);
            if (!fgets(confirmation, sizeof(confirmation), stdin)) return 8;
            if (strcmp(confirmation, "y\n")) return 9;
            if (!strcmp(argv[1], "--confirm-again")) {
                printf("Confirm again? (y/n): "); fflush(stdout);
                if (!fgets(confirmation, sizeof(confirmation), stdin)) return 10;
                return 11;
            }
        }
        if (!strcmp(argv[1], "--retry")) {
            password_mode();
            printf("Password: "); fflush(stdout);
            if (!fgets(password, sizeof(password), stdin)) return 2;
            printf("Password: "); fflush(stdout);
            if (!fgets(password, sizeof(password), stdin)) return 3;
            return 4;
        }
        if (!strcmp(argv[1], "--failure-output")) {
            fprintf(stderr,"final command diagnostic\n"); return 42;
        }
        if (!strcmp(argv[1], "--secret-output")) {
            printf("echo: fixture-pass"); fflush(stdout); usleep(20000);
            printf("word\n"); fflush(stdout); return 0;
        }
        printf("Enter the user"); fflush(stdout); usleep(20000);
        printf("name of an admin user: "); fflush(stdout);
        if (!fgets(user, sizeof(user), stdin)) return 5;
        password_mode();
        printf("Pass"); fflush(stdout); usleep(20000);
        printf("word: "); fflush(stdout);
        if (!fgets(password, sizeof(password), stdin)) return 6;
        return strcmp(user,"fixture-user\n") || strcmp(password,"fixture-password\n") ? 7 : 0;
    }
    char *child[] = {argv[0], "--child", NULL};
    int first = authorization_run(argv[0],child,"fixture-user","fixture-password",false);
    fprintf(stderr,"fixture status=%d\n", first);
    assert(first == 0);
    child[1] = "--getpass";
    int tty=authorization_run(argv[0],child,"fixture-user","fixture-password",true);
    if(tty!=0) { fprintf(stderr,"FAIL native getpass: status=%d\n",tty); return 1; }
    child[1] = "--native-confirm";
    int native=authorization_run(argv[0],child,"fixture-user","fixture-password",true);
    if(native!=0) { fprintf(stderr,"FAIL native kmutil prompt with newline: status=%d\n",native); return 1; }
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == UNEXPECTED_CONFIRMATION);
    child[1] = "--native-confirm-split";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == 0);
    child[1] = "--native-confirm-again";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == REPEATED_CONFIRMATION);
    child[1] = "--confirm";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == 0);
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == UNEXPECTED_CONFIRMATION);
    child[1] = "--confirm-again";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == REPEATED_CONFIRMATION);
    child[1] = "--retry";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == REPEATED_PASSWORD);
    assert(aurora_authorized_command(argv[0],child,"fixture-user","fixture-password") == -1);
    child[1] = "--failure-output";
    assert(authorization_run_logged(argv[0],child,"fixture-user","fixture-password",false,capture,NULL) == 42);
    assert(strstr(latest,"final command diagnostic"));
    child[1] = "--secret-output";
    assert(authorization_run_logged(argv[0],child,"fixture-user","fixture-password",false,capture,NULL) == 0);
    assert(strstr(latest,"[redacted]"));
    puts("PASS exact native kmutil prompt / newline / byte-split / repeated prompt; final output / exact exit status / fragmented credential redaction;  split confirmation/username/password prompts; exact one-shot confirmation; unauthorized/repeated confirmation rejection; repeated password rejection; command allowlist");
    return 0;
}
