#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "c_api.h"

@interface WebcamDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) uint8_t* buffer;
@property (nonatomic, assign) int bufferSize;
@property (nonatomic, assign) BOOL hasNewFrame;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, strong) NSCondition* frameCond;
@end

@implementation WebcamDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = NULL;
        _bufferSize = 0;
        _hasNewFrame = NO;
        _frameCond = [[NSCondition alloc] init];
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    uint8_t* baseAddress = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    
    [_frameCond lock];
    if (_buffer && _bufferSize >= (int)(width * height * 4)) {
        for (size_t y = 0; y < height; y++) {
            memcpy(_buffer + (y * width * 4), baseAddress + (y * bytesPerRow), width * 4);
        }
        _hasNewFrame = YES;
        [_frameCond signal];
    }
    [_frameCond unlock];

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

struct WebcamContext {
    void* session;
    void* delegate;
};

WebcamContext* webcam_open(int device_index, int width, int height) {
    @autoreleasepool {
        NSArray *deviceTypes = @[AVCaptureDeviceTypeBuiltInWideAngleCamera];
        AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession 
            discoverySessionWithDeviceTypes:deviceTypes 
            mediaType:AVMediaTypeVideo 
            position:AVCaptureDevicePositionUnspecified];
        
        NSArray *devices = discoverySession.devices;
        if (devices.count == 0 || device_index >= (int)devices.count) {
            return NULL;
        }
        
        AVCaptureDevice *device = devices[device_index];
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (error || !input) return NULL;
        
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [session beginConfiguration];
        if ([session canAddInput:input]) {
            [session addInput:input];
        } else {
            [session commitConfiguration];
            return NULL;
        }
        
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        
        WebcamDelegate *delegate = [[WebcamDelegate alloc] init];
        delegate.width = width;
        delegate.height = height;
        
        dispatch_queue_t queue = dispatch_queue_create("webcam_capture_queue", NULL);
        [output setSampleBufferDelegate:delegate queue:queue];
        
        if ([session canAddOutput:output]) {
            [session addOutput:output];
        } else {
            [session commitConfiguration];
            return NULL;
        }
        
        session.sessionPreset = AVCaptureSessionPreset640x480;
        [session commitConfiguration];
        [session startRunning];
        
        WebcamContext* ctx = (WebcamContext*)malloc(sizeof(WebcamContext));
        ctx->session = (__bridge_retained void*)session;
        ctx->delegate = (__bridge_retained void*)delegate;
        return ctx;
    }
}

void webcam_close(WebcamContext* ctx) {
    if (!ctx) return;
    @autoreleasepool {
        AVCaptureSession* session = (__bridge_transfer AVCaptureSession*)ctx->session;
        __attribute__((unused)) WebcamDelegate* delegate = (__bridge_transfer WebcamDelegate*)ctx->delegate;
        [session stopRunning];
    }
    free(ctx);
}

bool webcam_grab_frame(WebcamContext* ctx, uint8_t* buffer, int buffer_size) {
    if (!ctx) return false;
    @autoreleasepool {
        WebcamDelegate* delegate = (__bridge WebcamDelegate*)ctx->delegate;
        
        [delegate.frameCond lock];
        delegate.buffer = buffer;
        delegate.bufferSize = buffer_size;
        delegate.hasNewFrame = NO;
        
        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while (!delegate.hasNewFrame) {
            if (![delegate.frameCond waitUntilDate:timeout]) break;
        }
        
        delegate.buffer = NULL;
        delegate.bufferSize = 0;
        BOOL success = delegate.hasNewFrame;
        [delegate.frameCond unlock];
        
        return success;
    }
}