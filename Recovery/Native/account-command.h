#ifndef OMARCHY_ACCOUNT_COMMAND_H
#define OMARCHY_ACCOUNT_COMMAND_H
int omarchy_account_command(const char *path, const char *const *arguments,
                            const unsigned char *input, long input_size,
                            unsigned char **output, long *output_size,
                            unsigned timeout_seconds);
void omarchy_account_free(void *buffer, long size);
void omarchy_account_wipe(void *buffer, long size);
#endif
