#include "Authorization.h"
#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <signal.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#define LOG_LIMIT (64 * 1024)
#ifndef AUTHORIZATION_TIMEOUT_SECONDS
#define AUTHORIZATION_TIMEOUT_SECONDS 300
#endif
enum { INVALID=-1, PTY_FAILED=-2, TERMINAL_FAILED=-3, FORK_FAILED=-4,
       TIMED_OUT=-5, UNEXPECTED_CONFIRMATION=-6, REPEATED_CONFIRMATION=-7,
       REPEATED_PASSWORD=-8, REPEATED_USERNAME=-9, INPUT_FAILED=-10,
       OUTPUT_FAILED=-11, WAIT_FAILED=-12, CHILD_SIGNAL=-13 };

const char *aurora_authorization_failure(int result)
{
    switch(result) {
    case INVALID: return "invalid command or credential input";
    case PTY_FAILED: return "could not create the command terminal";
    case TERMINAL_FAILED: return "could not configure the command terminal";
    case FORK_FAILED: return "could not start the command process";
    case TIMED_OUT: return "command timed out waiting for input or completion";
    case UNEXPECTED_CONFIRMATION: return "unexpected confirmation prompt";
    case REPEATED_CONFIRMATION: return "command repeated its confirmation prompt";
    case REPEATED_PASSWORD: return "command asked for the password again";
    case REPEATED_USERNAME: return "command asked for the username again";
    case INPUT_FAILED: return "could not send the command response";
    case OUTPUT_FAILED: return "could not read command output";
    case WAIT_FAILED: return "could not collect the command result";
    case CHILD_SIGNAL: return "command was terminated by a signal";
    default: return "command exited unsuccessfully";
    }
}

static int send_line(int fd, const char *line)
{
    size_t size=strlen(line), offset=0;
    while(offset<size) {
        ssize_t n=write(fd,line+offset,size-offset);
        if(n<0 && errno==EINTR)continue;
        if(n<=0)return -1;
        offset+=(size_t)n;
    }
    return write(fd,"\n",1)==1 ? 0 : -1;
}

/* Snapshot logging deliberately withholds a suffix that could be a split
 * credential. No callback ever receives an unredacted password fragment. */
static void output_snapshot(const char *raw, size_t length, const char *secret,
                            bool truncated, aurora_log_callback output, void *context)
{
    if(!output)return;
    const char replacement[]="[redacted]";
    size_t secret_size=strlen(secret), used=0;
    char *clean=malloc(length*10+64);
    if(!clean)return;
    for(size_t pos=0;pos<length;) {
        size_t remaining=length-pos;
        if(secret_size<=remaining && !memcmp(raw+pos,secret,secret_size)) {
            memcpy(clean+used,replacement,sizeof(replacement)-1);
            used+=sizeof(replacement)-1;pos+=secret_size;
        } else if(remaining<secret_size && !memcmp(raw+pos,secret,remaining)) {
            break;
        } else clean[used++]=raw[pos++];
    }
    if(truncated) {
        const char notice[]="\n[command output limited to 64 KiB]\n";
        memcpy(clean+used,notice,sizeof(notice)-1);used+=sizeof(notice)-1;
    }
    clean[used]=0;output(clean,context);
    volatile char *wipe=clean;for(size_t i=0;i<used;i++)wipe[i]=0;
    free(clean);
}

static int authorization_run_logged(const char *executable, char *const arguments[],
                                    const char *username, const char *password,
                                    bool confirm_boot_object, aurora_log_callback output,
                                    void *context)
{
    if(!username || !password || !*username || !*password || strlen(password)>4096 ||
       strpbrk(username,"\r\n") || strpbrk(password,"\r\n"))return INVALID;
    int master,slave;
    if(openpty(&master,&slave,NULL,NULL,NULL))return PTY_FAILED;
    if(fcntl(master,F_SETFD,FD_CLOEXEC)<0 || fcntl(slave,F_SETFD,FD_CLOEXEC)<0) {
        close(master);close(slave);return PTY_FAILED;
    }
    struct termios term;
    if(tcgetattr(slave,&term)) { close(master);close(slave);return TERMINAL_FAILED; }
    /* Leave echo enabled for non-secret input. Password readers turn it off
     * themselves; that transition tells us their input flush has completed. */
    term.c_lflag |= ECHO;
    term.c_lflag &= ~ECHONL;
    if(tcsetattr(slave,TCSANOW,&term)) { close(master);close(slave);return TERMINAL_FAILED; }
    pid_t child=fork();
    if(child<0) { close(master);close(slave);return FORK_FAILED; }
    if(!child) {
        close(master);
        if(setsid()<0)_exit(121);
        if(ioctl(slave,TIOCSCTTY,0)<0)_exit(122);
        for(int fd=0;fd<3;fd++) {
            if(dup2(slave,fd)<0 || fcntl(fd,F_SETFD,0)<0)_exit(123);
        }
        if(slave>2)close(slave);
        execv(executable,arguments);_exit(127);
    }
    close(slave);
    int status=0,result=TIMED_OUT;
    bool exited=false,truncated=false,password_waiting=false;
    unsigned user_sent=0,password_sent=0,confirmation_sent=0;
    char pending[4096]={0}, line[4096]={0}, raw[LOG_LIMIT];
    size_t used=0,raw_used=0;
    time_t deadline=time(NULL)+AUTHORIZATION_TIMEOUT_SECONDS;
    for(;;) {
        if(!exited) {
            pid_t done=waitpid(child,&status,WNOHANG);
            if(done==child) { exited=true;result=WIFEXITED(status)?WEXITSTATUS(status):CHILD_SIGNAL; }
            else if(done<0) { if(errno==EINTR)continue;result=WAIT_FAILED;break; }
        }
        if(time(NULL)>=deadline) { result=TIMED_OUT;break; }
        /* kmutil prints Password: before getpass(""). Sending immediately
         * races getpass's TCSAFLUSH and loses the response. Wait for its echo
         * mode transition instead of guessing a delay or resending secrets. */
        if(password_waiting && !exited) {
            struct termios current;
            if(tcgetattr(master,&current)) { result=TERMINAL_FAILED;break; }
            if(!(current.c_lflag & (ECHO|ECHONL))) {
                if(send_line(master,password)) { result=INPUT_FAILED;break; }
                password_waiting=false;
            }
        }
        struct pollfd p={.fd=master,.events=POLLIN};
        if(poll(&p,1,exited?0:(password_waiting?10:200))<0) { if(errno==EINTR)continue;result=OUTPUT_FAILED;break; }
        if(!(p.revents&POLLIN)) { if(exited)break;continue; }
        char bytes[512];ssize_t n=read(master,bytes,sizeof(bytes));
        if(n<=0) {
            if(n==0 || errno==EIO) { if(exited)break;continue; }
            if(errno==EINTR)continue;
            result=OUTPUT_FAILED;break;
        }
        size_t take=(size_t)n<LOG_LIMIT-raw_used?(size_t)n:LOG_LIMIT-raw_used;
        memcpy(raw+raw_used,bytes,take);raw_used+=take;
        if(take<(size_t)n)truncated=true;
        output_snapshot(raw,raw_used,password,truncated,output,context);
        if(exited)continue; /* Drain the final error output before returning. */
        if(used+(size_t)n>=sizeof(pending)) {
            memmove(pending,pending+used/2,used-used/2);used-=used/2;
        }
        for(ssize_t i=0;i<n;i++)pending[used++]=(char)tolower((unsigned char)bytes[i]);
        pending[used]=0;
        /* Swift's kmutil prints its confirmation with a newline. Inspect the
         * last non-empty line without deleting whitespace from pending: a
         * later read may continue a prompt split at a space or punctuation. */
        size_t end=used;
        while(end && isspace((unsigned char)pending[end-1]))end--;
        size_t start=end;
        while(start && pending[start-1]!='\n' && pending[start-1]!='\r')start--;
        memcpy(line,pending+start,end-start);line[end-start]=0;
        const char *response=NULL;
        if(strstr(line,"[y/n]") || strstr(line,"(y/n)") ||
           strstr(line,"(enter y or n)")) {
            if(!confirm_boot_object) { result=UNEXPECTED_CONFIRMATION;break; }
            if(confirmation_sent++) { result=REPEATED_CONFIRMATION;break; }
            response="y";
        } else if(strchr(line,':') && strstr(line,"password")) {
            if(password_sent++) { result=REPEATED_PASSWORD;break; }
            password_waiting=true;
            used=0;pending[0]=0;
        } else if(strchr(line,':') && (strstr(line,"username") || strstr(line,"user name") ||
                  strstr(line,"authorized user"))) {
            /* bputil asks "Authorized user:" before its password prompt. */
            if(user_sent++) { result=REPEATED_USERNAME;break; }
            response=username;
        }
        if(response) {
            if(send_line(master,response)) { result=INPUT_FAILED;break; }
            used=0;pending[0]=0;
        }
    }
    /* The session belongs exclusively to this launch. Also terminate a helper
     * holding the PTY after its direct parent has already exited. */
    kill(-child,SIGKILL);
    if(!exited) { kill(child,SIGKILL);while(waitpid(child,&status,0)<0 && errno==EINTR){} }
    output_snapshot(raw,raw_used,password,truncated,output,context);
    volatile char *wipe=pending;for(size_t i=0;i<sizeof(pending);i++)wipe[i]=0;
    wipe=line;for(size_t i=0;i<sizeof(line);i++)wipe[i]=0;
    wipe=raw;for(size_t i=0;i<raw_used;i++)wipe[i]=0;
    close(master);return result;
}

static bool allowed(const char *executable)
{
    return executable && (!strcmp(executable,"/usr/bin/bputil") ||
        !strcmp(executable,"/usr/bin/kmutil") || !strcmp(executable,"/usr/sbin/bless"));
}
static int authorization_run(const char *executable, char *const arguments[],
                              const char *username, const char *password, bool confirm)
{
    return authorization_run_logged(executable,arguments,username,password,confirm,NULL,NULL);
}
int aurora_authorized_command(const char *executable,char *const arguments[],
                              const char *username,const char *password)
{
    if(!allowed(executable) || !arguments || !arguments[0])return INVALID;
    bool confirm=!strcmp(executable,"/usr/bin/kmutil") && arguments[1] && !strcmp(arguments[1],"configure-boot");
    return authorization_run(executable,arguments,username,password,confirm);
}
int aurora_authorized_command_logged(const char *executable,char *const arguments[],
                                     const char *username,const char *password,
                                     aurora_log_callback output,void *context)
{
    if(!allowed(executable) || !arguments || !arguments[0])return INVALID;
    bool confirm=!strcmp(executable,"/usr/bin/kmutil") && arguments[1] && !strcmp(arguments[1],"configure-boot");
    return authorization_run_logged(executable,arguments,username,password,confirm,output,context);
}
