#include "account-command.h"
#include <dlfcn.h>
#include <uuid/uuid.h>

int omarchy_apfs_volume_group_uuid(const char *device, char *output, long capacity)
{
    if (!device || !output || capacity < 37)
        return -1;
    void *library = dlopen("/System/Library/PrivateFrameworks/APFS.framework/APFS", RTLD_LAZY);
    if (!library)
        return -1;
    int (*get_group)(const char *, uuid_t) = dlsym(library, "APFSGetVolumeGroupID");
    int result = -1;
    if (get_group) {
        uuid_t uuid = {0};
        result = get_group(device, uuid);
        if (!result)
            uuid_unparse_upper(uuid, output);
    }
    dlclose(library);
    return result;
}
