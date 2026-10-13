typedef void (*aurora_log_callback)(const char *text, void *context);
int aurora_authorized_command(const char *executable, char *const arguments[],
                              const char *username, const char *password);
int aurora_authorized_command_logged(const char *executable, char *const arguments[],
                                     const char *username, const char *password,
                                     aurora_log_callback output, void *context);
const char *aurora_authorization_failure(int result);
