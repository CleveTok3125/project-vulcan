/*
 * LD_PRELOAD shim for glycin inside containers.
 *
 * Glycin normally sandboxes image loaders with bubblewrap. The nested
 * container cannot create that sandbox, so image loading fails. Disable the
 * sandbox selector after each loader/creator is created.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct _GFile GFile;
typedef struct _GBytes GBytes;
typedef struct _GInputStream GInputStream;
typedef struct _GlyLoader GlyLoader;
typedef struct _GlyCreator GlyCreator;
typedef int gboolean;

#define GLY_SANDBOX_SELECTOR_NOT_SANDBOXED 3

static void (*p_gly_loader_set_sandbox_selector)(GlyLoader *, int);
static gboolean (*p_gly_creator_set_sandbox_selector)(GlyCreator *, int);
static GlyLoader *(*real_gly_loader_new)(GFile *);
static GlyLoader *(*real_gly_loader_new_for_stream)(GInputStream *);
static GlyLoader *(*real_gly_loader_new_for_bytes)(GBytes *);
static GlyCreator *(*real_gly_creator_new)(const char *);

static void resolve_symbols(void) {
    if (!real_gly_loader_new)
        real_gly_loader_new = dlsym(RTLD_NEXT, "gly_loader_new");
    if (!real_gly_loader_new_for_stream)
        real_gly_loader_new_for_stream = dlsym(RTLD_NEXT, "gly_loader_new_for_stream");
    if (!real_gly_loader_new_for_bytes)
        real_gly_loader_new_for_bytes = dlsym(RTLD_NEXT, "gly_loader_new_for_bytes");
    if (!real_gly_creator_new)
        real_gly_creator_new = dlsym(RTLD_NEXT, "gly_creator_new");
    if (!p_gly_loader_set_sandbox_selector)
        p_gly_loader_set_sandbox_selector = dlsym(RTLD_NEXT, "gly_loader_set_sandbox_selector");
    if (!p_gly_creator_set_sandbox_selector)
        p_gly_creator_set_sandbox_selector = dlsym(RTLD_NEXT, "gly_creator_set_sandbox_selector");
}

static GlyLoader *disable_loader(GlyLoader *loader) {
    if (loader && p_gly_loader_set_sandbox_selector)
        p_gly_loader_set_sandbox_selector(loader, GLY_SANDBOX_SELECTOR_NOT_SANDBOXED);
    return loader;
}

static GlyCreator *disable_creator(GlyCreator *creator) {
    if (creator && p_gly_creator_set_sandbox_selector)
        p_gly_creator_set_sandbox_selector(creator, GLY_SANDBOX_SELECTOR_NOT_SANDBOXED);
    return creator;
}

GlyLoader *gly_loader_new(GFile *file) {
    resolve_symbols();
    return disable_loader(real_gly_loader_new ? real_gly_loader_new(file) : NULL);
}

GlyLoader *gly_loader_new_for_stream(GInputStream *stream) {
    resolve_symbols();
    return disable_loader(real_gly_loader_new_for_stream ? real_gly_loader_new_for_stream(stream) : NULL);
}

GlyLoader *gly_loader_new_for_bytes(GBytes *bytes) {
    resolve_symbols();
    return disable_loader(real_gly_loader_new_for_bytes ? real_gly_loader_new_for_bytes(bytes) : NULL);
}

GlyCreator *gly_creator_new(const char *mime) {
    resolve_symbols();
    return disable_creator(real_gly_creator_new ? real_gly_creator_new(mime) : NULL);
}
