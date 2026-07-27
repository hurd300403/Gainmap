// C bridge for the S1 device spike: run the in-process encoder once.
// Returns a malloc'd result string ("clamps: ..." on success, "error: ..." on
// failure); caller frees.
#ifndef SPIKE_BRIDGE_H
#define SPIKE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

char *spike_encode(const char *rawPath, int width, int height,
                   const char *sdrPath, const char *outPath);

#ifdef __cplusplus
}
#endif

#endif
