#define WIN32_LEAN_AND_MEAN
#include <initguid.h> // Must be first! Instantiates standard Microsoft GUIDs in this object file
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h> 
#include "c_api.h"

struct WebcamContext {
    IMFSourceReader* pReader;
    bool com_initialized;
    bool mf_initialized;
};

WebcamContext* webcam_open(int device_index, int width, int height) {
    WebcamContext* ctx = (WebcamContext*)malloc(sizeof(WebcamContext));
    if (!ctx) return NULL;
    ctx->pReader = NULL;
    ctx->com_initialized = false;
    ctx->mf_initialized = false;

    // Use multithreaded apartment to be thread-safe
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
    if (SUCCEEDED(hr) || hr == S_FALSE) {
        ctx->com_initialized = true;
    } else {
        fprintf(stderr, "webcam_open: CoInitializeEx failed (0x%08X)\n", hr);
        free(ctx);
        return NULL;
    }

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (SUCCEEDED(hr)) {
        ctx->mf_initialized = true;
    } else {
        fprintf(stderr, "webcam_open: MFStartup failed (0x%08X)\n", hr);
        CoUninitialize();
        free(ctx);
        return NULL;
    }

    IMFAttributes* pAttributes = NULL;
    hr = MFCreateAttributes(&pAttributes, 1);
    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: MFCreateAttributes failed (0x%08X)\n", hr);
        webcam_close(ctx);
        return NULL;
    }

    // Using standard Microsoft GUIDs directly
    hr = pAttributes->lpVtbl->SetGUID(pAttributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: SetGUID for source type failed (0x%08X)\n", hr);
        pAttributes->lpVtbl->Release(pAttributes);
        webcam_close(ctx);
        return NULL;
    }

    IMFActivate** ppDevices = NULL;
    UINT32 count = 0;
    hr = MFEnumDeviceSources(pAttributes, &ppDevices, &count);
    pAttributes->lpVtbl->Release(pAttributes);

    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: MFEnumDeviceSources failed (0x%08X)\n", hr);
        webcam_close(ctx);
        return NULL;
    }
    if (count == 0) {
        fprintf(stderr, "webcam_open: No video capture devices found on this system.\n");
        webcam_close(ctx);
        return NULL;
    }
    if (device_index >= (int)count) {
        fprintf(stderr, "webcam_open: Requested device index %d, but only %u devices were found.\n", device_index, count);
        webcam_close(ctx);
        return NULL;
    }

    IMFMediaSource* pSource = NULL;
    hr = ppDevices[device_index]->lpVtbl->ActivateObject(ppDevices[device_index], &IID_IMFMediaSource, (void**)&pSource);

    // Clean up all enumerated activation devices
    for (UINT32 i = 0; i < count; i++) {
        ppDevices[i]->lpVtbl->Release(ppDevices[i]);
    }
    CoTaskMemFree(ppDevices);

    if (FAILED(hr)) {
        if (hr == E_ACCESSDENIED || hr == 0x80070005) {
             fprintf(stderr, "webcam_open: ActivateObject failed with E_ACCESSDENIED. Check your Windows Camera Privacy Settings.\n");
        } else {
             fprintf(stderr, "webcam_open: ActivateObject failed (0x%08X)\n", hr);
        }
        webcam_close(ctx);
        return NULL;
    }

    // Create reader configuration attributes to enable internal color processing/conversion
    IMFAttributes* pReaderAttributes = NULL;
    hr = MFCreateAttributes(&pReaderAttributes, 1);
    if (SUCCEEDED(hr)) {
        hr = pReaderAttributes->lpVtbl->SetUINT32(pReaderAttributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: Failed to prepare reader attributes (0x%08X)\n", hr);
        if (pReaderAttributes) pReaderAttributes->lpVtbl->Release(pReaderAttributes);
        pSource->lpVtbl->Release(pSource);
        webcam_close(ctx);
        return NULL;
    }

    // Create the Source Reader with processing enabled
    hr = MFCreateSourceReaderFromMediaSource(pSource, pReaderAttributes, &ctx->pReader);
    pReaderAttributes->lpVtbl->Release(pReaderAttributes);
    pSource->lpVtbl->Release(pSource); // The reader manages the reference now

    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: MFCreateSourceReaderFromMediaSource failed (0x%08X)\n", hr);
        webcam_close(ctx);
        return NULL;
    }

    // Set the output stream selection
    hr = ctx->pReader->lpVtbl->SetStreamSelection(ctx->pReader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: SetStreamSelection failed (0x%08X)\n", hr);
        webcam_close(ctx);
        return NULL;
    }

    // Configure the target media type (RGB32 with specified size)
    IMFMediaType* pType = NULL;
    hr = MFCreateMediaType(&pType);
    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: MFCreateMediaType failed (0x%08X)\n", hr);
        webcam_close(ctx);
        return NULL;
    }

    hr = pType->lpVtbl->SetGUID(pType, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    if (SUCCEEDED(hr)) {
        hr = pType->lpVtbl->SetGUID(pType, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32);
    }
    if (SUCCEEDED(hr)) {
        hr = pType->lpVtbl->SetUINT64(pType, &MF_MT_FRAME_SIZE, ((UINT64)width << 32) | height);
    }

    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: Setting target media type attributes failed (0x%08X)\n", hr);
        pType->lpVtbl->Release(pType);
        webcam_close(ctx);
        return NULL;
    }

    hr = ctx->pReader->lpVtbl->SetCurrentMediaType(ctx->pReader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, pType);
    pType->lpVtbl->Release(pType);

    if (FAILED(hr)) {
        fprintf(stderr, "webcam_open: SetCurrentMediaType failed (0x%08X). The camera format conversion or resolution of %dx%d is unsupported.\n", hr, width, height);
        webcam_close(ctx);
        return NULL;
    }

    return ctx;
}

void webcam_close(WebcamContext* ctx) {
    if (!ctx) return;
    if (ctx->pReader) {
        ctx->pReader->lpVtbl->Release(ctx->pReader);
    }
    if (ctx->mf_initialized) {
        MFShutdown();
    }
    if (ctx->com_initialized) {
        CoUninitialize();
    }
    free(ctx);
}

bool webcam_grab_frame(WebcamContext* ctx, uint8_t* buffer, int buffer_size) {
    if (!ctx || !ctx->pReader) return false;

    DWORD streamIndex = 0;
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    IMFSample* pSample = NULL;
    HRESULT hr = S_OK;

    // Retry loop: some cameras generate metadata/ticks and warm up with NULL samples first.
    // We try up to 300 times with a 10ms delay (providing up to 3 seconds of warm-up tolerance).
    int attempts = 0;
    while (attempts < 300) {
        pSample = NULL;
        flags = 0;

        hr = ctx->pReader->lpVtbl->ReadSample(
            ctx->pReader,
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
            0,
            &streamIndex,
            &flags,
            &timestamp,
            &pSample
        );

        if (FAILED(hr)) {
            return false;
        }

        // We got a real sample with pixel data!
        if (pSample) {
            break;
        }

        // If the driver tells us the stream has actually ended, abort.
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            return false;
        }

        // Wait a tiny bit for the next driver tick/event to resolve.
        Sleep(10);
        attempts++;
    }

    if (!pSample) {
        return false;
    }

    IMFMediaBuffer* pMediaBuffer = NULL;
    hr = pSample->lpVtbl->GetBufferByIndex(pSample, 0, &pMediaBuffer);
    if (SUCCEEDED(hr)) {
        BYTE* pData = NULL;
        DWORD cbMaxLength = 0;
        DWORD cbCurrentLength = 0;
        hr = pMediaBuffer->lpVtbl->Lock(pMediaBuffer, &pData, &cbMaxLength, &cbCurrentLength);
        if (SUCCEEDED(hr)) {
            DWORD copy_size = cbCurrentLength;
            if (copy_size > (DWORD)buffer_size) {
                copy_size = (DWORD)buffer_size;
            }
            memcpy(buffer, pData, copy_size);
            pMediaBuffer->lpVtbl->Unlock(pMediaBuffer);
        }
        pMediaBuffer->lpVtbl->Release(pMediaBuffer);
    }
    pSample->lpVtbl->Release(pSample);

    return SUCCEEDED(hr);
}