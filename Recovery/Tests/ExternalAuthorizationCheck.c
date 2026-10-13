#include "../Native/Authorization.c"
#include <stdio.h>
static void capture_external(const char *text, void *context) { (void)context; fprintf(stderr,"SNAPSHOT %s\n",text); }
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 char *child[]={argv[1],NULL};
 int result=authorization_run_logged(argv[1],child,"fixture-user","fixture-password",true,capture_external,NULL);
 fprintf(stderr,"External fixture result=%d\n",result);return result?1:0;
}
