#ifndef WEBCAM_C_API_H
#define WEBCAM_C_API_H

#include <stdint.h>
#include <stdbool.h>

typedef struct WebcamContext WebcamContext;

// OpenCV-esque minimal C life-cycle
WebcamContext* webcam_open(int device_index, int width, int height);
void webcam_close(WebcamContext* ctx);
bool webcam_grab_frame(WebcamContext* ctx, uint8_t* buffer, int buffer_size);

#endif